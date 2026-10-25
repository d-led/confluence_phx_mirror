defmodule ConfluencePhxMirror.Mcp.Tools.Search do
  @moduledoc """
  The two search tools: `confluence_search` (what a Confluence client expects)
  and `confluence_advanced_search` (the filters the reader UI offers).

  `confluence_search` takes one `query` that may be either CQL or plain words.
  The guess is a heuristic, so a query that looks like CQL and does not parse
  falls back to a text search instead of failing: a model typing
  `how do I ~ deploy` means words, not a broken expression.

  Neither tool filters permissions itself. `Mirror.Search` answers "what
  matches" and `Authorization.readable_results/2` answers "what may this reader
  see", the same split the HTML search and `/api/v1/search` use.
  """

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mcp.Args
  alias ConfluencePhxMirror.Mcp.Tools.Pages
  alias ConfluencePhxMirror.Mirror.Search

  # The arguments the UI's advanced form sends; anything else in a tool call
  # (limits, sorting) is handled here and must not leak into a CQL clause.
  @filter_keys ~w(q phrase any none space spaces label labels type types creator ancestor updated updated_after from to title)

  # CQL shows itself in either a field comparison or a boolean operator. A text
  # query that happens to match is handled by the fallback below.
  @cql_hint ~r/[=~]|!=|\b(AND|OR|NOT)\b|\bORDER\s+BY\b/i

  @doc "`confluence_search`: a text query, or CQL when the query looks like it."
  def search(args, scope) do
    with {:ok, query} <- Args.required(args, "query"),
         {:ok, limit} <- Args.integer(args, "limit", default: 10, min: 1, max: 50),
         {:ok, spaces} <- spaces_filter(args) do
      if Regex.match?(@cql_hint, query) do
        cql(query, scope, limit, spaces)
      else
        text(query, scope, limit, spaces)
      end
    end
  end

  @doc "`confluence_advanced_search`: the UI's text boxes and field filters."
  def advanced(args, scope) do
    with {:ok, limit} <- Args.integer(args, "limit", default: 10, min: 1, max: 50),
         {:ok, start} <- Args.integer(args, "start", default: 0, min: 0, max: 10_000),
         {:ok, sort} <- Args.one_of(args, "sort", ~w(relevance newest oldest), "relevance"),
         params <- Map.take(args, @filter_keys),
         :ok <- filtered?(params) do
      structured(params, scope, limit: limit, start: start, sort: sort_atom(sort))
    end
  end

  # ---------------------------------------------------------------------------
  # The two engines
  # ---------------------------------------------------------------------------

  defp text(query, scope, limit, spaces) do
    params =
      if spaces == [],
        do: %{"q" => query},
        else: %{"q" => query, "spaces" => Enum.join(spaces, ",")}

    structured(params, scope, limit: limit, start: 0, sort: :relevance)
  end

  defp cql(query, scope, limit, spaces) do
    # A space filter is applied after the query: CQL has its own space clause,
    # and rewriting a caller's expression is worse than widening the read and
    # keeping the matches that are in the spaces asked for.
    scan = if spaces == [], do: limit, else: max(limit * 5, 50)

    case Search.search(query, limit: scan, start: 0) do
      {:ok, results} ->
        hits =
          scope
          |> Authorization.readable_results(results)
          |> Enum.filter(&in_spaces?(&1, spaces))
          |> Enum.take(limit)

        {:ok, %{text: results_text(hits), structured: %{"results" => Enum.map(hits, &hit/1)}}}

      {:error, _not_cql} ->
        text(query, scope, limit, spaces)
    end
  end

  defp structured(params, scope, opts) do
    case Search.structured(params, opts) do
      {:ok, results, _terms} ->
        hits = Authorization.readable_results(scope, results)
        {:ok, %{text: results_text(hits), structured: %{"results" => Enum.map(hits, &hit/1)}}}

      {:error, message} ->
        {:error, message}
    end
  end

  # ---------------------------------------------------------------------------
  # Arguments
  # ---------------------------------------------------------------------------

  defp spaces_filter(args) do
    with {:ok, value} <- Args.optional(args, "spaces_filter") do
      {:ok, keys(value)}
    end
  end

  defp keys(nil), do: []

  defp keys(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp filtered?(params) do
    if Enum.all?(params, fn {_key, value} -> value in [nil, ""] end) do
      {:error,
       "Provide `q`, `phrase`, `any` or `none`, and/or one of: " <>
         "space, spaces, label, type, creator, ancestor, updated, from, to."}
    else
      :ok
    end
  end

  defp sort_atom("newest"), do: :newest
  defp sort_atom("oldest"), do: :oldest
  defp sort_atom(_relevance), do: :relevance

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp in_spaces?(_result, []), do: true
  defp in_spaces?(result, spaces), do: result.page.space.key in spaces

  defp hit(result) do
    result.page
    |> Pages.summary()
    |> Map.put("snippet", snippet(result.snippet))
    |> Map.put("rank", Float.round(result.rank * 1.0, 4))
    |> Map.put("matchedComment", comment(result.comment))
  end

  defp comment(nil), do: nil

  defp comment(comment) do
    %{
      "id" => to_string(comment.confluence_id),
      "author" => comment.author_name,
      "created" => Pages.iso(comment.external_created_at)
    }
  end

  defp results_text([]) do
    "No content matches. Try fewer words, or confluence_advanced_search with a space or label filter."
  end

  defp results_text(hits) do
    Enum.map_join(Enum.with_index(hits, 1), "\n\n", fn {result, index} ->
      summary = Pages.summary(result.page)

      "#{index}. #{summary["title"]} (id #{summary["id"]}, #{summary["space"]})\n" <>
        "   #{summary["url"]}" <> snippet_line(result.snippet) <> comment_line(result.comment)
    end)
  end

  # A hit found in a comment quotes the comment, so the line says whose words
  # those are — the page itself did not say them.
  defp comment_line(nil), do: ""

  defp comment_line(comment) do
    "\n   matched in a comment by #{comment.author_name || "Anonymous"}" <>
      case Pages.iso(comment.external_created_at) do
        nil -> ""
        date -> " on #{date}"
      end
  end

  defp snippet_line(snippet) do
    case snippet(snippet) do
      "" -> ""
      text -> "\n   " <> text
    end
  end

  # Body text arrives with the page's own line breaks; one line per hit keeps a
  # result list readable without inlining a paragraph of newlines.
  defp snippet(nil), do: ""
  defp snippet(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()
end
