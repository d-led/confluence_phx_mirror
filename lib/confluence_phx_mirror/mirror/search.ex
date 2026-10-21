defmodule ConfluencePhxMirror.Mirror.Search do
  @moduledoc """
  Executes CQL against Postgres full-text search.

  The filter is compiled to parameterised SQL so it can use the stored
  generated `search_vector` column and its GIN index directly (Ecto does not
  know the `tsvector` type). Matching page ids and their rank are fetched in
  one query; the page structs are then loaded by id through Ecto and returned
  in rank order.

  Label and ancestor filters are array containment checks backed by GIN
  indexes, so structured filters never walk the page tree.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Mirror.Search.{CQL, Filters, TextQuery}
  alias ConfluencePhxMirror.Repo

  @language "simple"

  # Paging is deployment-sized (see config/runtime.exs), not a code constant.
  defp search_config, do: Application.get_env(:confluence_phx_mirror, :search, [])

  defp default_limit, do: Keyword.get(search_config(), :default_limit, 25)
  defp max_limit, do: Keyword.get(search_config(), :max_limit, 100)

  # When text and field filters are combined, both sides are scanned wider than
  # the page size so the intersection is not truncated.
  defp max_result_scan, do: max_limit() * 50

  @type result :: %{
          page: Page.t(),
          space: ConfluencePhxMirror.Mirror.Space.t(),
          rank: float(),
          snippet: String.t()
        }

  @doc """
  Structured search used by the UI and the v1 API.

  `params` may contain `q`, `space`, `label`, `type`, `creator`, `ancestor` and
  `updated` (`7d`, `30d`, `90d`, `365d` or an ISO date). Returns results and the
  terms to highlight.
  """
  @spec structured(map(), keyword()) ::
          {:ok, [result()], [String.t()]} | {:error, String.t()}
  def structured(params, opts \\ []) do
    params = Filters.normalise(params)
    q = params["q"] || ""
    field_params = Map.drop(params, ["q"])
    fields? = Enum.any?(Filters.field_keys(), &(field_params[&1] not in [nil, ""]))

    cond do
      q == "" and not fields? ->
        {:ok, [], []}

      q != "" and not fields? ->
        {:ok, results} = text(q, opts)
        {:ok, results, text_terms(q)}

      q == "" ->
        case Filters.to_cql(field_params) do
          {:ok, cql, _terms} ->
            case search(cql, opts) do
              {:ok, results} -> {:ok, results, []}
              {:error, message} -> {:error, message}
            end

          :empty ->
            {:ok, [], []}
        end

      true ->
        # Text and fields are both present: rank by text, keep only pages that
        # satisfy the field filters. The bound keeps the intersection cheap.
        {:ok, field_cql, _} = Filters.to_cql(field_params)
        {:ok, field_results} = search(field_cql, limit: max_result_scan())
        allowed = MapSet.new(field_results, & &1.page.id)

        {:ok, text_results} = text(q, limit: max_result_scan())

        limit = min(Keyword.get(opts, :limit, default_limit()), max_limit())
        offset = max(Keyword.get(opts, :start, 0), 0)

        results =
          text_results
          |> Enum.filter(&MapSet.member?(allowed, &1.page.id))
          |> Enum.drop(offset)
          |> Enum.take(limit)

        {:ok, results, text_terms(q)}
    end
  end

  defp text_terms(q) do
    case TextQuery.parse(q) do
      {:ok, _tsquery, terms} -> terms
      _ -> Filters.terms(q)
    end
  end

  @doc """
  Full-text search across every indexed field (title, body, labels, author,
  space and attachment filenames).

  Plain words are ANDed and matched by prefix; `AND`/`OR`/`NOT` (uppercase),
  parentheses, quoted phrases and a leading `-` are supported. Malformed input
  falls back to Postgres' forgiving `websearch_to_tsquery`.
  """
  @spec text(String.t(), keyword()) :: {:ok, [result()]}
  def text(query, opts \\ []) do
    query = String.trim(query || "")
    limit = min(Keyword.get(opts, :limit, default_limit()), max_limit())
    offset = max(Keyword.get(opts, :start, 0), 0)

    case TextQuery.parse(query) do
      :empty ->
        {:ok, []}

      {:ok, tsquery, terms} ->
        run_text(tsquery, "to_tsquery", terms, limit, offset)

      :error ->
        run_text(query, "websearch_to_tsquery", fallback_terms(query), limit, offset)
    end
  end

  # The SQL is a template: every user value becomes a $N parameter (see
  # param/2), and the only interpolations are the fixed language/function names
  # and the integer limit/offset.
  # sobelow_skip ["SQL.Query"]
  defp run_text(parameter, function, terms, limit, offset) do
    sql = """
    SELECT p.id, ts_rank_cd(p.search_vector, #{function}('#{@language}', $1)) AS rank
    FROM pages p
    JOIN spaces s ON s.id = p.space_id
    WHERE p.deleted_at IS NULL
      AND p.search_vector @@ #{function}('#{@language}', $1)
    ORDER BY rank DESC, p.external_updated_at DESC NULLS LAST
    LIMIT #{Integer.to_string(limit)} OFFSET #{Integer.to_string(offset)}
    """

    rows = Repo.query!(sql, [parameter]).rows
    ids = Enum.map(rows, fn [id, _rank] -> id end)
    rank_by_id = Map.new(rows, fn [id, rank] -> {id, rank} end)

    results =
      ids
      |> load_pages()
      |> Enum.map(fn page ->
        %{
          page: page,
          space: page.space,
          rank: rank_by_id[page.id] || 0.0,
          snippet: snippet(page, terms)
        }
      end)

    {:ok, results}
  end

  defp fallback_terms(query) do
    query
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/u, ""))
    |> Enum.reject(&(String.length(&1) < 2))
  end

  @doc """
  Parses and executes `cql`.

  Options: `:start` (offset, default 0) and `:limit` (default 25, max 100).
  """
  @spec search(String.t(), keyword()) :: {:ok, [result()]} | {:error, String.t()}
  def search(cql, opts \\ []) do
    with {:ok, query} <- CQL.parse(cql) do
      {:ok, execute(query, opts)}
    end
  end

  # Same template as run_text/5: filters arrive as $N parameters and every
  # identifier comes from a fixed clause (scalar/4, order_sql/3).
  # sobelow_skip ["SQL.Query"]
  defp execute(%CQL.Query{} = query, opts) do
    limit = min(query.limit || Keyword.get(opts, :limit, default_limit()), max_limit())
    offset = max(Keyword.get(opts, :start, 0), 0)
    terms = terms(query.filter)
    text_query = Enum.join(terms, " ")

    {sql, params} = build_sql(query, text_query, limit, offset)
    rows = Repo.query!(sql, params).rows

    ids = Enum.map(rows, fn [id, _rank] -> id end)
    rank_by_id = Map.new(rows, fn [id, rank] -> {id, rank} end)

    load_pages(ids)
    |> Enum.map(fn page ->
      %{
        page: page,
        space: page.space,
        rank: rank_by_id[page.id] || 0.0,
        snippet: snippet(page, terms)
      }
    end)
  end

  defp load_pages([]), do: []

  defp load_pages(ids) do
    pages =
      Repo.all(
        from p in Page,
          where: p.id in ^ids,
          preload: [:space]
      )

    by_id = Map.new(pages, &{&1.id, &1})
    Enum.flat_map(ids, fn id -> List.wrap(by_id[id]) end)
  end

  # ---------------------------------------------------------------------------
  # SQL builder
  # ---------------------------------------------------------------------------

  @doc false
  def build_sql(%CQL.Query{filter: filter, order_by: order_by}, text_query, limit, offset) do
    builder = %{params: [], next: 1}

    {condition, builder} = condition(filter, builder)
    {text_param, builder} = param(builder, text_query)
    {order_sql, builder} = order_sql(order_by, text_query, builder)

    sql = """
    SELECT p.id, ts_rank_cd(p.search_vector, websearch_to_tsquery('#{@language}', #{text_param})) AS rank
    FROM pages p
    JOIN spaces s ON s.id = p.space_id
    WHERE p.deleted_at IS NULL AND (#{condition})
    ORDER BY #{order_sql}
    LIMIT #{Integer.to_string(limit)} OFFSET #{Integer.to_string(offset)}
    """

    {sql, builder.params}
  end

  # Boolean composition -------------------------------------------------------

  defp condition({:and, left, right}, builder) do
    {l, builder} = condition(left, builder)
    {r, builder} = condition(right, builder)
    {"(#{l} AND #{r})", builder}
  end

  defp condition({:or, left, right}, builder) do
    {l, builder} = condition(left, builder)
    {r, builder} = condition(right, builder)
    {"(#{l} OR #{r})", builder}
  end

  defp condition({:not, inner}, builder) do
    {sql, builder} = condition(inner, builder)
    {"(NOT #{sql})", builder}
  end

  defp condition({:cmp, field, op, value}, builder), do: comparison(field, op, value, builder)

  # Comparisons ---------------------------------------------------------------

  defp comparison(:text, :contains, value, builder) do
    {placeholder, builder} = param(builder, value)

    {"p.search_vector @@ websearch_to_tsquery('#{@language}', #{placeholder})", builder}
  end

  defp comparison(:title, :contains, value, builder) do
    {placeholder, builder} = param(builder, value)

    {"to_tsvector('#{@language}', p.title) @@ websearch_to_tsquery('#{@language}', #{placeholder})",
     builder}
  end

  defp comparison(:title, op, value, builder) when op in [:eq, :neq] do
    {placeholder, builder} = param(builder, value)
    sql_op = if op == :eq, do: "=", else: "!="
    {"(lower(p.title) #{sql_op} lower(#{placeholder}))", builder}
  end

  defp comparison(:space, op, value, builder) when op in [:eq, :neq] do
    {placeholder, builder} = param(builder, value)
    sql_op = if op == :eq, do: "=", else: "!="
    {"(upper(s.key) #{sql_op} upper(#{placeholder}))", builder}
  end

  defp comparison(:label, op, value, builder) when op in [:eq, :neq] do
    {placeholder, builder} = param(builder, String.downcase(String.trim(value)))
    sql = "#{placeholder} = ANY(p.labels)"
    {if(op == :eq, do: "(#{sql})", else: "(NOT #{sql})"), builder}
  end

  defp comparison(:type, op, value, builder) when op in [:eq, :neq] do
    {placeholder, builder} = param(builder, String.downcase(value))
    sql_op = if op == :eq, do: "=", else: "!="
    {"(p.type #{sql_op} #{placeholder})", builder}
  end

  defp comparison(:status, op, value, builder) when op in [:eq, :neq] do
    {placeholder, builder} = param(builder, String.downcase(value))
    sql_op = if op == :eq, do: "=", else: "!="
    {"(p.status #{sql_op} #{placeholder})", builder}
  end

  defp comparison(:creator, :eq, value, builder) do
    {placeholder, builder} = param(builder, value)
    {"(lower(p.author_name) = lower(#{placeholder}))", builder}
  end

  defp comparison(:ancestor, :eq, value, builder) do
    {placeholder, builder} = param(builder, value)
    {"(#{placeholder} = ANY(p.ancestors))", builder}
  end

  defp comparison(:parent, :eq, value, builder) do
    {placeholder, builder} = param(builder, value)
    {"(p.parent_id IN (SELECT id FROM pages WHERE confluence_id = #{placeholder}))", builder}
  end

  defp comparison(:id, :eq, value, builder) do
    {placeholder, builder} = param(builder, value)
    {"(p.confluence_id = #{placeholder})", builder}
  end

  defp comparison(:version, op, value, builder),
    do: scalar("p.version_number", op, value, builder)

  defp comparison(:created, op, value, builder),
    do: scalar("p.external_created_at", op, value, builder)

  defp comparison(:lastmodified, op, value, builder),
    do: scalar("p.external_updated_at", op, value, builder)

  defp comparison(field, op, _value, _builder) do
    raise ArgumentError, "unsupported CQL comparison: #{field} #{op}"
  end

  defp scalar(column, op, value, builder) do
    {placeholder, builder} = param(builder, value)
    sql_op = sql_operator(op)
    {"(#{column} #{sql_op} #{placeholder})", builder}
  end

  defp sql_operator(:eq), do: "="
  defp sql_operator(:neq), do: "!="
  defp sql_operator(:gt), do: ">"
  defp sql_operator(:gte), do: ">="
  defp sql_operator(:lt), do: "<"
  defp sql_operator(:lte), do: "<="

  # Ordering ------------------------------------------------------------------

  defp order_sql(nil, "", builder), do: {"p.external_updated_at DESC NULLS LAST", builder}

  defp order_sql(nil, _text_query, builder),
    do: {"rank DESC, p.external_updated_at DESC NULLS LAST", builder}

  defp order_sql({field, direction}, _text_query, builder) do
    column =
      case field do
        :lastmodified -> "p.external_updated_at"
        :created -> "p.external_created_at"
        :version -> "p.version_number"
        :title -> "p.title"
        :id -> "p.confluence_id"
      end

    dir = if direction == :asc, do: "ASC", else: "DESC"
    {"#{column} #{dir} NULLS LAST", builder}
  end

  defp param(builder, value) do
    placeholder = "$" <> Integer.to_string(builder.next)
    {placeholder, %{builder | params: builder.params ++ [value], next: builder.next + 1}}
  end

  # ---------------------------------------------------------------------------
  # Snippets
  # ---------------------------------------------------------------------------

  @doc "Extracts the search terms from a parsed filter, used for snippets."
  def terms(nil), do: []

  def terms({:or, left, right}), do: terms(left) ++ terms(right)
  def terms({:and, left, right}), do: terms(left) ++ terms(right)
  def terms({:not, inner}), do: terms(inner)
  def terms({:cmp, field, :contains, value}) when field in [:text, :title], do: [value]
  def terms({:cmp, _, _, _}), do: []

  @doc "A short plain-text snippet around the first matching term."
  def snippet(%Page{body_text: nil}, _terms), do: ""
  def snippet(%Page{body_text: ""}, _terms), do: ""

  def snippet(%Page{body_text: text}, terms) do
    downcased = String.downcase(text)

    position =
      Enum.find_value(terms, fn term ->
        case :binary.match(downcased, String.downcase(term)) do
          {start, _length} -> start
          :nomatch -> nil
        end
      end)

    snippet =
      case position do
        nil -> String.slice(text, 0, 220)
        start -> String.slice(text, max(start - 80, 0), 240)
      end

    String.trim(snippet)
  end
end
