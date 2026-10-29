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

  Text is not only a page's own: a comment is content a reader remembers just
  as often, so a page whose comment matches is a hit, and the result says which
  comment it matched in so the screen can show those words instead of an
  unrelated paragraph of the page.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Mirror.{Comment, Page}
  alias ConfluencePhxMirror.Mirror.Search.{CQL, Filters, TextQuery}
  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings

  @language "simple"

  # The same expression as `comments_search_vector_idx` (see the migration): an
  # expression index is only used for an identical expression, so the two must
  # stay in step.
  @comment_vector "to_tsvector('#{@language}', coalesce(c.author_name, '') || ' ' || coalesce(c.body_text, ''))"

  # Paging is an administrator's decision, falling back to the deployment's own
  # configuration (`CM_SEARCH_*`); see ConfluencePhxMirror.Settings.
  defp default_limit, do: Settings.search_default_limit()
  defp max_limit, do: Settings.search_max_results()

  # When text and field filters are combined, both sides are scanned wider than
  # the page size so the intersection is not truncated.
  defp max_result_scan, do: max_limit() * 50

  @type result :: %{
          page: Page.t(),
          space: ConfluencePhxMirror.Mirror.Space.t(),
          rank: float(),
          snippet: String.t(),
          comment: Comment.t() | nil
        }

  @doc """
  Structured search used by the UI and the v1 API.

  `params` may contain the text boxes advanced search offers (`q`, `phrase`,
  `any`, `none`), the field filters (`space`, `spaces`, `label`, `type`,
  `creator`, `ancestor`, `updated`, `from`, `to`).

  Options: `:sort` (`:relevance` by default, `:newest` or `:oldest`),
  `:limit` and `:start`.
  """
  @spec structured(map(), keyword()) ::
          {:ok, [result()], [String.t()]} | {:error, String.t()}
  def structured(params, opts \\ []) do
    params = Filters.normalise(params)
    q = Filters.compose_text(params)
    field_params = Map.drop(params, ["q", "phrase", "any", "none"])
    fields? = Enum.any?(Filters.field_keys(), &(field_params[&1] not in [nil, ""]))

    cond do
      q == "" and not fields? ->
        {:ok, [], []}

      q != "" and not fields? ->
        {:ok, results} = text(q, scan_opts(opts))
        {:ok, page(results, opts), text_terms(q)}

      q == "" ->
        case Filters.to_cql(field_params) do
          {:ok, cql, _terms} ->
            case search(cql, scan_opts(opts)) do
              {:ok, results} -> {:ok, page(results, opts), []}
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

        results = Enum.filter(text_results, &MapSet.member?(allowed, &1.page.id))
        {:ok, page(results, opts), text_terms(q)}
    end
  end

  # Sorting by recency is a different question from "what matches best", so the
  # ranking is replaced wholesale rather than used as a tie-break — and the scan
  # has to be wide enough for the page to be taken after sorting.
  defp scan_opts(opts) do
    case sort(opts) do
      :relevance -> opts
      _ -> Keyword.put(opts, :limit, max_result_scan())
    end
  end

  defp page(results, opts) do
    limit = min(Keyword.get(opts, :limit, default_limit()), max_limit())
    offset = max(Keyword.get(opts, :start, 0), 0)

    results
    |> sorted(sort(opts))
    |> Enum.drop(offset)
    |> Enum.take(limit)
  end

  defp sort(opts), do: Keyword.get(opts, :sort, :relevance)

  defp sorted(results, :relevance), do: results

  defp sorted(results, :newest),
    do: Enum.sort_by(results, &updated_at/1, {:desc, DateTime})

  defp sorted(results, :oldest), do: Enum.sort_by(results, &updated_at/1, {:asc, DateTime})

  defp updated_at(result), do: result.page.external_updated_at || ~U[1970-01-01 00:00:00Z]

  defp text_terms(q) do
    case TextQuery.parse(q) do
      {:ok, _tsquery, terms} -> terms
      _ -> Filters.terms(q)
    end
  end

  @doc """
  Full-text search across every indexed field (title, body, labels, author,
  space and attachment filenames), and across comments.

  A comment is authored content, so a page whose comment matches is a hit; the
  result carries that comment so the snippet shows the words the reader typed
  rather than an unrelated part of the page. A page's own match wins over its
  comments, so one page is one result.

  Plain words are ANDed and matched by prefix; `AND`/`OR`/`NOT` (uppercase),
  parentheses, quoted phrases and a leading `-` are supported. Malformed input
  falls back to Postgres' forgiving `websearch_to_tsquery`.

  A one-word query that comes up short is asked again as a fragment: the text
  index matches lexeme prefixes, so "escal" finds "Escalation" and "scal" does
  not. What the second pass finds is appended, never interleaved — a word that
  starts with the query is a better match than one that merely contains it, and
  the reader sees that order. Comments take part in the word pass only: the
  fragment pass is an extra over page text, not a promise about comments.

  `scal*` asks for that first band alone: a star on the end of the last word is
  the usual way to say "a word that begins like this", and it turns the fragment
  pass off, so the answer is exactly the pages whose word starts there.

  A query that is nothing but a number is also a page id, and finds that page:
  Confluence ids are what a colleague pastes in from a URL or a ticket, and they
  are in no text index. The id is looked up on its own index and ranked above
  every word match.
  """
  @spec text(String.t(), keyword()) :: {:ok, [result()]}
  def text(query, opts \\ []) do
    query = String.trim(query || "")
    limit = min(Keyword.get(opts, :limit, default_limit()), max_limit())
    offset = max(Keyword.get(opts, :start, 0), 0)
    page_id = page_id_term(query)

    case TextQuery.parse(query) do
      :empty ->
        {:ok, []}

      {:ok, tsquery, terms} ->
        with {:ok, results} <- run_text(tsquery, "to_tsquery", terms, limit, offset, page_id) do
          if page_id || prefix_only?(query) do
            {:ok, results}
          else
            {:ok, inside_words(results, query, terms, limit)}
          end
        end

      :error ->
        run_text(query, "websearch_to_tsquery", fallback_terms(query), limit, offset, page_id)
    end
  end

  # A whole query that is a number is an id, not a word. A number among other
  # words is not: "426221 roadmap" is somebody searching for words.
  defp page_id_term(query) do
    case Integer.parse(query) do
      {id, ""} when id > 0 -> id
      _not_an_id -> nil
    end
  end

  # A star on the last word is how a reader says "a word that starts this way":
  # the prefix band is already the first thing a query answers with, and the star
  # keeps it the only thing. The query language strips it before it reaches
  # Postgres, so `scal*` and `scal` are the same tsquery — the difference is the
  # second pass that one of them skips.
  defp prefix_only?(query), do: String.ends_with?(query, "*")

  # Only when the prefix pass left room: a reader who typed a word the mirror
  # knows pays one query, and the trigram pass costs nothing for them.
  defp inside_words(results, query, terms, limit) do
    word = fragment(query)
    room = limit - length(results)

    if is_binary(word) and room > 0 do
      found = fragment_matches(word, room, Enum.map(results, & &1.page.id))
      results ++ fragment_results(found, terms)
    else
      results
    end
  end

  # One bare word, and nothing that means something to the query language: a
  # phrase, a negation or a boolean has no single fragment to look for. Three
  # characters is the floor a trigram index can work with — below it the same
  # predicate becomes a scan of every page's text, which is why "z" stays a
  # prefix-only search.
  defp fragment(query) do
    if String.length(query) >= 3 and Regex.match?(~r/^[\p{L}\p{N}_]+$/u, query) do
      String.downcase(query)
    end
  end

  # The trigram index answers this in milliseconds (`pages_search_text_trgm_idx`),
  # where the same predicate without it is a sequential scan of every page's text.
  # `%` and `_` are LIKE wildcards, so a word carrying them is escaped rather than
  # matched loosely.
  # sobelow_skip ["SQL.Query"]
  defp fragment_matches(word, limit, exclude_ids) do
    pattern = "%" <> String.replace(word, ~r/[\\%_]/, "\\\\\\0") <> "%"

    sql = """
    SELECT p.id, word_similarity($1, coalesce(p.title, '')) AS score
    FROM pages p
    JOIN spaces s ON s.id = p.space_id
    WHERE p.deleted_at IS NULL
      AND p.id <> ALL($2)
      AND (p.title ILIKE $3 OR p.search_text ILIKE $3)
    ORDER BY score DESC, p.external_updated_at DESC NULLS LAST
    LIMIT #{Integer.to_string(limit)}
    """

    Repo.query!(sql, [word, exclude_ids, pattern]).rows
  end

  defp fragment_results(rows, terms) do
    rows
    |> Enum.map(fn [id, _score] -> [id, 0.0, nil] end)
    |> results(terms)
  end

  # The SQL is a template: every user value becomes a $N parameter (see
  # param/2), and the only interpolations are the fixed language/function names
  # and the integer limit/offset.
  #
  # A page and a comment are two rows that mean one hit: the page's own text is
  # preferred, so the comment branch skips pages the page branch already found,
  # and `band` keeps every page hit above every comment hit whatever the two
  # ranks happen to be. One row per page keeps paging honest.
  #
  # `band` has a second job: a page whose title answers the query sits above one
  # that merely repeats the word. `ts_rank_cd` counts occurrences, so a page of
  # listings — a macros gallery, an index, a table of contents — would otherwise
  # outrank the page it names, which is the one thing a reader never meant.
  # sobelow_skip ["SQL.Query"]
  defp run_text(parameter, function, terms, limit, offset, page_id) do
    tsquery = "#{function}('#{@language}', $1)"

    # The id arm is written only when there is an id: a `$2` the query does not
    # use is a parameter Postgres refuses.
    by_id = if page_id, do: "OR p.confluence_id = $2", else: ""
    id_band = if page_id, do: "WHEN p.confluence_id = $2 THEN 3", else: ""
    params = if page_id, do: [parameter, page_id], else: [parameter]

    sql = """
    SELECT page_id, rank, comment_id
    FROM (
      SELECT p.id AS page_id,
             ts_rank_cd(p.search_vector, #{tsquery}) AS rank,
             NULL::bigint AS comment_id,
             CASE
               #{id_band}
               WHEN setweight(to_tsvector('#{@language}', coalesce(p.title, '')), 'A') @@ #{tsquery}
               THEN 2 ELSE 1
             END AS band,
             p.external_updated_at AS updated_at
      FROM pages p
      JOIN spaces s ON s.id = p.space_id
      WHERE p.deleted_at IS NULL
        AND (p.search_vector @@ #{tsquery} #{by_id})

      UNION ALL

      SELECT best.page_id, best.rank, best.comment_id, 0, best.updated_at
      FROM (
        SELECT DISTINCT ON (p.id)
               p.id AS page_id,
               ts_rank_cd(#{@comment_vector}, #{tsquery}) AS rank,
               c.id AS comment_id,
               p.external_updated_at AS updated_at
        FROM comments c
        JOIN pages p ON p.id = c.page_id
        JOIN spaces s ON s.id = p.space_id
        WHERE c.deleted_at IS NULL
          AND p.deleted_at IS NULL
          AND #{comments_published()}
          AND #{@comment_vector} @@ #{tsquery}
          AND NOT EXISTS (
            SELECT 1 FROM pages p2
            WHERE p2.id = p.id AND p2.search_vector @@ #{tsquery}
          )
        ORDER BY p.id, rank DESC
      ) best
    ) hits
    ORDER BY band DESC, rank DESC, updated_at DESC NULLS LAST
    LIMIT #{Integer.to_string(limit)} OFFSET #{Integer.to_string(offset)}
    """

    {:ok, Repo.query!(sql, params).rows |> results(terms)}
  end

  # One row per page: `[page_id, rank, comment_id]`. The comment is loaded for
  # the rows that name one, in a single statement for the whole page of results.
  defp results(rows, terms) do
    pages = rows |> Enum.map(&hd/1) |> load_pages() |> Map.new(&{&1.id, &1})
    comments = rows |> Enum.map(fn [_, _, comment_id] -> comment_id end) |> load_comments()

    Enum.flat_map(rows, fn [id, rank, comment_id] ->
      case pages[id] do
        nil -> []
        page -> [result(page, rank, comments[comment_id], terms)]
      end
    end)
  end

  defp result(page, rank, nil, terms) do
    %{page: page, space: page.space, rank: rank, snippet: snippet(page, terms), comment: nil}
  end

  defp result(page, rank, comment, terms) do
    %{
      page: page,
      space: page.space,
      rank: rank,
      snippet: snippet(comment, terms),
      comment: comment
    }
  end

  defp load_comments(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      Repo.all(from c in Comment, where: c.id in ^ids) |> Map.new(&{&1.id, &1})
    end
  end

  defp fallback_terms(query) do
    query
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/u, ""))
    |> Enum.reject(&(String.length(&1) < 2))
  end

  @doc """
  Parses and executes `cql`.

  `text ~` reads pages and their comments, the same question the structured
  search answers.

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

    ids = Enum.map(rows, fn [id | _] -> id end)
    rank_by_id = Map.new(rows, fn [id, rank | _] -> {id, rank} end)
    comments = comment_hits(rows, text_query)

    load_pages(ids)
    |> Enum.map(fn page ->
      comment = comments[page.id]

      %{
        page: page,
        space: page.space,
        rank: rank_by_id[page.id] || 0.0,
        snippet: snippet(comment || page, terms),
        comment: comment
      }
    end)
  end

  # A page the text clause found through a comment has no matching words of its
  # own, so the best matching comment is asked for separately — one statement
  # for the whole page of results, and only when some row says the page itself
  # did not match.
  #
  # A deployment that publishes no comments searches none of them: the hit would
  # name a page through text nobody may read, and the snippet would quote it.
  # `comments_published/0` is the same constant the text clause uses, so the two
  # cannot drift apart.
  defp comments_published, do: if(Publishing.exclude_comments?(), do: "false", else: "true")

  defp comment_hits(_rows, ""), do: %{}

  # The two identifiers are the fixed expression and language above; the page
  # ids and the query are parameters.
  # sobelow_skip ["SQL.Query"]
  defp comment_hits(rows, text_query) do
    page_ids = for [id, _rank, false] <- rows, do: id

    cond do
      page_ids == [] -> %{}
      Publishing.exclude_comments?() -> %{}
      true -> matching_comments(page_ids, text_query)
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp matching_comments(page_ids, text_query) do
    sql = """
    SELECT DISTINCT ON (c.page_id) c.page_id, c.id
    FROM comments c
    WHERE c.page_id = ANY($1)
      AND c.deleted_at IS NULL
      AND #{@comment_vector} @@ websearch_to_tsquery('#{@language}', $2)
    ORDER BY c.page_id,
             ts_rank_cd(#{@comment_vector}, websearch_to_tsquery('#{@language}', $2)) DESC
    """

    rows = Repo.query!(sql, [page_ids, text_query]).rows
    comments = rows |> Enum.map(fn [_page_id, comment_id] -> comment_id end) |> load_comments()

    Map.new(rows, fn [page_id, comment_id] -> {page_id, comments[comment_id]} end)
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
    SELECT p.id, ts_rank_cd(p.search_vector, websearch_to_tsquery('#{@language}', #{text_param})) AS rank,
           p.search_vector @@ websearch_to_tsquery('#{@language}', #{text_param}) AS page_matched
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

  defp condition({:in, field, values}, builder), do: membership(field, values, :in, builder)

  defp condition({:not_in, field, values}, builder),
    do: membership(field, values, :not_in, builder)

  # Set membership ------------------------------------------------------------

  # Eight fields are plain columns, read from one table so a new one is a line
  # here rather than another clause. A text column compares lowercased; a number
  # or an instant compares as the parser typed it.
  @membership_columns %{
    title: {"lower(p.title)", :text},
    type: {"p.type", :text},
    status: {"p.status", :text},
    creator: {"lower(p.author_name)", :text},
    id: {"p.confluence_id", :value},
    version: {"p.version_number", :value},
    created: {"p.external_created_at", :value},
    lastmodified: {"p.external_updated_at", :value}
  }

  defp membership(:space, values, kind, builder) do
    array_membership(
      "upper(s.key)",
      Enum.map(values, &(&1 |> to_string() |> String.upcase())),
      kind,
      builder
    )
  end

  # A page can carry several labels, so "one of these labels" is an overlap with
  # the stored array rather than an equality.
  defp membership(:label, values, kind, builder) do
    {placeholder, builder} =
      param(builder, Enum.map(values, &(&1 |> to_string() |> String.trim() |> String.downcase())))

    {wrap(kind, "p.labels && #{placeholder}"), builder}
  end

  defp membership(:ancestor, values, kind, builder) do
    {placeholder, builder} = param(builder, values)
    {wrap(kind, "#{placeholder} && p.ancestors"), builder}
  end

  defp membership(:parent, values, kind, builder) do
    {placeholder, builder} = param(builder, values)

    {wrap(
       kind,
       "p.parent_id IN (SELECT id FROM pages WHERE confluence_id = ANY(#{placeholder}))"
     ), builder}
  end

  defp membership(field, values, kind, builder) do
    case Map.get(@membership_columns, field) do
      nil -> raise ArgumentError, "unsupported CQL membership: #{field}"
      {column, :text} -> array_membership(column, downcased(values), kind, builder)
      {column, :value} -> array_membership(column, values, kind, builder)
    end
  end

  defp array_membership(column, values, kind, builder) do
    {placeholder, builder} = param(builder, values)
    {wrap(kind, "#{column} = ANY(#{placeholder})"), builder}
  end

  defp wrap(:in, sql), do: "(#{sql})"
  defp wrap(:not_in, sql), do: "(NOT #{sql})"

  defp downcased(values), do: Enum.map(values, &(&1 |> to_string() |> String.downcase()))

  # Comparisons ---------------------------------------------------------------

  defp comparison(:text, :contains, value, builder) do
    {placeholder, builder} = param(builder, value)
    matches = "websearch_to_tsquery('#{@language}', #{placeholder})"

    condition = """
    (p.search_vector @@ #{matches}
     OR EXISTS (
       SELECT 1 FROM comments c
       WHERE c.page_id = p.id
         AND c.deleted_at IS NULL
         AND #{@comment_vector} @@ #{matches}
     ))
    """

    {condition, builder}
  end

  defp comparison(:title, :contains, value, builder) do
    {placeholder, builder} = param(builder, value)

    {"to_tsvector('#{@language}', p.title) @@ websearch_to_tsquery('#{@language}', #{placeholder})",
     builder}
  end

  # "does not contain" is the negation of a match, not a separate index lookup:
  # one definition of what containing means, so the two cannot drift apart.
  defp comparison(:text, :not_contains, value, builder) do
    {condition, builder} = comparison(:text, :contains, value, builder)
    {"(NOT #{condition})", builder}
  end

  defp comparison(:title, :not_contains, value, builder) do
    {condition, builder} = comparison(:title, :contains, value, builder)
    {"(NOT #{condition})", builder}
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

  defp order_sql([], text_query, builder), do: order_sql(nil, text_query, builder)

  defp order_sql(order_by, _text_query, builder) when is_list(order_by) do
    {Enum.map_join(order_by, ", ", &order_column/1), builder}
  end

  defp order_column({field, direction}) do
    dir = if direction == :asc, do: "ASC", else: "DESC"
    "#{order_column_name(field)} #{dir} NULLS LAST"
  end

  defp order_column_name(:lastmodified), do: "p.external_updated_at"
  defp order_column_name(:created), do: "p.external_created_at"
  defp order_column_name(:version), do: "p.version_number"
  defp order_column_name(:title), do: "p.title"
  defp order_column_name(:id), do: "p.confluence_id"

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
  def terms({:in, _, _}), do: []
  def terms({:not_in, _, _}), do: []

  # The snippet opens on a word boundary: a cut inside a word reads as corrupt
  # text ("ry platform service has a runbook"), so the window starts after the
  # next space and says, with an ellipsis, that it started mid-sentence.
  @snippet_lead 80
  @snippet_length 240

  @doc "A short plain-text snippet around the first matching term."
  def snippet(%Page{body_text: nil}, _terms), do: ""
  def snippet(%Page{body_text: ""}, _terms), do: ""
  def snippet(%Comment{body_text: nil}, _terms), do: ""
  def snippet(%Comment{body_text: ""}, _terms), do: ""
  def snippet(%Page{body_text: text}, terms) when is_binary(text), do: text_snippet(text, terms)

  def snippet(%Comment{body_text: text}, terms) when is_binary(text),
    do: text_snippet(text, terms)

  def snippet(%Page{}, _terms), do: ""
  def snippet(%Comment{}, _terms), do: ""

  defp text_snippet(text, terms) do
    case first_match(text, terms) do
      nil -> text |> String.slice(0, @snippet_length) |> String.trim()
      start -> text |> window(start) |> String.trim()
    end
  end

  defp window(text, start) do
    from = max(start - @snippet_lead, 0)
    slice = String.slice(text, from, @snippet_length)

    if from == 0 do
      slice
    else
      case :binary.match(slice, " ") do
        {offset, 1} -> "… " <> String.slice(slice, offset + 1, byte_size(slice))
        :nomatch -> slice
      end
    end
  end

  defp first_match(text, terms) do
    downcased = String.downcase(text)

    Enum.find_value(terms, fn term ->
      case :binary.match(downcased, String.downcase(term)) do
        {start, _length} -> start
        :nomatch -> nil
      end
    end)
  end
end
