defmodule ConfluencePhxMirror.Mirror.Search.Lite do
  @moduledoc """
  Full-text search over a SQLite store: FTS5.

  The server's engine is `tsvector`, `ts_rank_cd` and GIN over a generated column.
  A build whose store is a file has the same question to answer with the index
  SQLite has: a `pages_fts` table (`content='pages'`, kept in step by triggers —
  see the migration that creates it), whose `MATCH` is answered from the term
  index and ranked by `bm25`. Both are an index lookup over a million pages, not
  a scan, which is the whole reason for having a table instead of a `LIKE`.

  What is deliberately not here:

    * **comments are not a second index.** A hit is a page's own title and body.
      The server matches comments too because it has an expression index for
      them; half an index with a different recall would be worse than saying so.
    * **CQL is not parsed** (`search/2` answers with a sentence). CQL is the
      Confluence-compatible API's language; the reader UI builds its filters as
      parameters, and those are all supported here.

  The SQL is written for one engine on purpose: `?` placeholders, FTS5's `bm25()`,
  `json_each` for the JSON columns. This module is only ever called when the repo
  is SQLite — see `ConfluencePhxMirror.Mirror.Search`.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Mirror.Search
  alias ConfluencePhxMirror.Mirror.Search.Filters
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings

  @no_cql "This mirror answers searches as filters, not as CQL: the query language " <>
            "belongs to the Confluence-compatible API, which needs the Postgres build."

  # A word longer than this is not a word: it is a paste accident, and the
  # tokenizer would spend the query's budget on it.
  @longest_word 60

  defp default_limit, do: Settings.search_default_limit()
  defp max_limit, do: Settings.search_max_results()

  @doc """
  Structured search: the reader's words, and the field filters around them.

  `params` is what the search screen holds — `q`, `phrase`, `any`, `none`, and the
  field filters (`space`, `spaces`, `label`, `labels`, `type`, `types`, `creator`,
  `ancestor`, `updated`, `from`, `to`). Options: `:sort` (`:relevance`,
  `:newest`, `:oldest`), `:limit`, `:start`.
  """
  @spec structured(map(), keyword()) ::
          {:ok, [Search.result()], [String.t()]} | {:error, String.t()}
  def structured(params, opts \\ []) do
    params = Filters.normalise(params)
    terms = Filters.terms(params["q"])
    expression = match_expression(params)
    excluded = exclusions(params)
    {filters, values} = filters(params)

    if is_nil(expression) and excluded == [] and filters == "" do
      {:ok, [], terms}
    else
      case run(expression, excluded, filters, values, terms, opts) do
        {:ok, results} -> {:ok, results, terms}
        {:error, message} -> {:error, message}
      end
    end
  end

  @doc """
  The reader's words alone, without the field filters.

  What the header box asks on every keystroke.
  """
  @spec text(String.t(), keyword()) :: {:ok, [Search.result()]}
  def text(query, opts \\ []) do
    run(match_expression(%{"q" => query}), [], "", [], Filters.terms(query), opts)
  end

  @doc false
  @spec search(String.t(), keyword()) :: {:error, String.t()}
  def search(_cql, _opts), do: {:error, @no_cql}

  # ---------------------------------------------------------------------------
  # The query language the reader actually types
  # ---------------------------------------------------------------------------

  @doc """
  The FTS5 `MATCH` expression for the reader's words, or `nil` when they typed
  none.

  Every word is a quoted token with a `*`, so typing is a prefix search: "scal"
  finds "scale" and "scaling" before the reader finishes the word. A phrase is
  quoted, which FTS5 reads as adjacent tokens. "Any of these" becomes an `OR`
  group. Everything else — quotes, brackets, `*`, `-` — is punctuation to a
  search box, so it is stripped rather than handed to the query language as
  syntax.
  """
  @spec match_expression(map()) :: String.t() | nil
  def match_expression(params) do
    parts =
      [
        params |> Map.get("q", "") |> words() |> Enum.map_join(" AND ", &prefix/1),
        phrase(params["phrase"]),
        any_group(params["any"])
      ]
      |> Enum.reject(&(&1 == ""))

    case parts do
      [] -> nil
      parts -> Enum.join(parts, " AND ")
    end
  end

  @doc """
  The words the reader excluded with "none of these".

  FTS5 has no unary `NOT` — `a NOT b` is a binary operator — so an exclusion is
  applied as its own `NOT IN (… pages_fts MATCH …)` clause rather than folded
  into the expression above. That also keeps it working when there are no
  positive words at all.
  """
  @spec exclusions(map()) :: [String.t()]
  def exclusions(params) do
    params |> Map.get("none", "") |> words() |> Enum.map(&prefix/1)
  end

  defp prefix(word), do: ~s("#{word}"*)

  defp phrase(value) do
    case words(value) do
      [] -> ""
      words -> ~s("#{Enum.join(words, " ")}")
    end
  end

  defp any_group(value) do
    case words(value) do
      [] -> ""
      words -> "(" <> Enum.map_join(words, " OR ", &prefix/1) <> ")"
    end
  end

  defp words(nil), do: []

  defp words(value) do
    value
    |> to_string()
    |> String.replace(~r/[^\p{L}\p{N}_]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.reject(&(String.length(&1) > @longest_word))
  end

  # ---------------------------------------------------------------------------
  # The query
  # ---------------------------------------------------------------------------

  # The statement is assembled from clauses written here, and every value the
  # reader supplies — the words, the exclusions, the filters — is a `?` bound in
  # `values`. Nothing from `params` reaches the string.
  # sobelow_skip ["SQL.Query"]
  defp run(expression, excluded, filters, filter_values, terms, opts) do
    limit = min(Keyword.get(opts, :limit, default_limit()), max_limit())
    offset = max(Keyword.get(opts, :start, 0), 0)

    sql = sql(expression, excluded, filters, Keyword.get(opts, :sort, :relevance))
    values = if(expression, do: [expression], else: []) ++ excluded ++ filter_values

    case Repo.query(sql, values ++ [limit, offset]) do
      {:ok, %{rows: rows}} -> {:ok, load(rows, terms)}
      {:error, reason} -> {:error, "the search index could not be read: #{inspect(reason)}"}
    end
  end

  # The same statement shape whether or not there are words: with an expression
  # the FTS table drives (one index walk, ranked); without one the pages do, and
  # the date is what orders them.
  defp sql(nil, _excluded, filters, _sort) do
    """
    SELECT p.id, 0.0 AS score
    FROM pages p
    JOIN spaces s ON s.id = p.space_id
    WHERE p.deleted_at IS NULL AND s.deleted_at IS NULL#{filters}
    ORDER BY p.external_updated_at DESC, p.id DESC
    LIMIT ? OFFSET ?
    """
  end

  defp sql(expression, excluded, filters, sort) do
    """
    SELECT p.id, bm25(pages_fts) AS score
    FROM pages_fts
    JOIN pages p ON p.id = pages_fts.rowid
    JOIN spaces s ON s.id = p.space_id
    WHERE #{expression_clause(expression)}
      AND p.deleted_at IS NULL AND s.deleted_at IS NULL#{filters}#{exclusions_clause(excluded)}
    ORDER BY #{order(sort)}
    LIMIT ? OFFSET ?
    """
  end

  defp expression_clause(_expression), do: "pages_fts MATCH ?"

  defp exclusions_clause(excluded) do
    Enum.map_join(excluded, "", fn _term ->
      "\n      AND p.id NOT IN (SELECT rowid FROM pages_fts WHERE pages_fts MATCH ?)"
    end)
  end

  # `bm25()` is lower-is-better and negative; `:newest` and `:oldest` sort on the
  # date the page was last changed upstream, which is what a reader means by
  # "recent" in a mirror.
  defp order(:relevance), do: "score, p.external_updated_at DESC"
  defp order(:newest), do: "p.external_updated_at DESC, score"
  defp order(:oldest), do: "p.external_updated_at ASC, score"

  defp filters(params) do
    params
    |> Enum.reduce({[], []}, fn
      {_key, value}, acc when value in [nil, ""] ->
        acc

      {"q", _value}, acc ->
        acc

      {"phrase", _value}, acc ->
        acc

      {"any", _value}, acc ->
        acc

      {"none", _value}, acc ->
        acc

      {"space", key}, {sql, values} ->
        {sql ++ ["s.key = ?"], values ++ [upcase(key)]}

      {"spaces", keys}, {sql, values} ->
        in_space(sql, values, keys)

      {"label", name}, acc ->
        exists_label(acc, name)

      {"labels", names}, acc ->
        names
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reduce(acc, &exists_label(&2, &1))

      {"type", type}, {sql, values} ->
        {sql ++ ["p.type = ?"], values ++ [String.downcase(type)]}

      {"types", types}, {sql, values} ->
        list =
          types
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.downcase/1)

        {sql ++ ["p.type IN (#{Enum.map_join(list, ",", fn _ -> "?" end)})"], values ++ list}

      {"creator", creator}, {sql, values} ->
        {sql ++ ["(p.author_account_id = ? OR p.author_name = ?)"], values ++ [creator, creator]}

      {"ancestor", id}, {sql, values} ->
        {sql ++ ["EXISTS (SELECT 1 FROM json_each(p.ancestors) WHERE value = ?)"], values ++ [id]}

      {"updated", value}, acc ->
        after_date(acc, value)

      {"updated_after", value}, acc ->
        after_date(acc, value)

      {"from", value}, acc ->
        before_or_after(acc, value, ">")

      {"to", value}, acc ->
        before_or_after(acc, value, "<")

      {"title", title}, {sql, values} ->
        {sql ++ ["lower(coalesce(p.title, '')) LIKE lower(?)"],
         values ++ ["%#{escape_like(title)}%"]}

      {_unknown, _value}, acc ->
        acc
    end)
    |> then(fn {sql, values} -> {Enum.map_join(sql, "", &("\n      AND " <> &1)), values} end)
  end

  defp in_space(sql, values, keys) do
    keys =
      keys
      |> String.split(",", trim: true)
      |> Enum.map(&(&1 |> String.trim() |> upcase()))
      |> Enum.reject(&(&1 == ""))

    case keys do
      [] -> {sql, values}
      keys -> {sql ++ ["s.key IN (#{Enum.map_join(keys, ",", fn _ -> "?" end)})"], values ++ keys}
    end
  end

  defp exists_label({sql, values}, name) do
    name = name |> String.trim() |> String.downcase()

    if name == "" do
      {sql, values}
    else
      {sql ++
         [
           "EXISTS (SELECT 1 FROM page_labels pl JOIN labels l ON l.id = pl.label_id " <>
             "WHERE pl.page_id = p.id AND l.name = ?)"
         ], values ++ [name]}
    end
  end

  defp after_date(acc, value) do
    case Filters.cutoff(value) do
      nil -> acc
      date -> before_or_after(acc, date, ">")
    end
  end

  defp before_or_after({sql, values}, date, operator) do
    {sql ++ ["date(p.external_updated_at) #{operator} ?"], values ++ [date]}
  end

  # A space key is upper case in Confluence and typed in any case by a reader.
  defp upcase(key), do: key |> to_string() |> String.trim() |> String.upcase()

  # `%` and `_` are LIKE's own, and a title filter is a substring, not a pattern.
  defp escape_like(value), do: String.replace(value, ~r/[\\%_]/, "\\\\\\0")

  # ---------------------------------------------------------------------------
  # Results
  # ---------------------------------------------------------------------------

  defp load([], _terms), do: []

  defp load(rows, terms) do
    ids = Enum.map(rows, fn [id, _score] -> id end)
    scores = Map.new(rows, fn [id, score] -> {id, score} end)

    # `space` is loaded onto the page, not only carried beside it: the search
    # result component reads `page.space.name`, and a struct whose association is
    # `NotLoaded` raises where a page would render. The Postgres engine answers
    # the same shape.
    from(p in Page,
      join: s in assoc(p, :space),
      where: p.id in ^ids,
      preload: [space: s]
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
    |> then(fn found ->
      Enum.flat_map(ids, fn id ->
        case Map.fetch(found, id) do
          # Gone between the index read and this one: a purge that ran in between
          # is not a reason to fail the search.
          :error ->
            []

          {:ok, page} ->
            [
              %{
                page: page,
                space: page.space,
                # `bm25()` is negative and lower-is-better; every other engine in
                # this application reports a rank that is higher-is-better.
                rank: -Map.fetch!(scores, id),
                snippet: Search.snippet(page, terms),
                comment: nil
              }
            ]
        end
      end)
    end)
  end
end
