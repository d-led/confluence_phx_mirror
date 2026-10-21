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
  alias ConfluencePhxMirror.Mirror.Search.CQL
  alias ConfluencePhxMirror.Repo

  @default_limit 25
  @max_limit 100
  @language "simple"

  @type result :: %{
          page: Page.t(),
          space: ConfluencePhxMirror.Mirror.Space.t(),
          rank: float(),
          snippet: String.t()
        }

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

  defp execute(%CQL.Query{} = query, opts) do
    limit = min(query.limit || Keyword.get(opts, :limit, @default_limit), @max_limit)
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
