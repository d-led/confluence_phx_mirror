defmodule ConfluencePhxMirror.Sync.DynamicContent.Included do
  @moduledoc """
  Reading another page's body as if the reader were on that page.

  Two macros do it — *Include Page* and *Excerpt Include* — and both have to end,
  so both ask here. The body of the included page is expanded with **its** page
  as the context (its headings, its space, its listings), which is why a table of
  contents inside an include lists the included page's headings and not the
  host's.

  Termination is the interesting part. A page may include itself, directly or in
  a ring, and nothing in Confluence stops it: the stored body of A says "include
  B" and the stored body of B says "include A". Two guards, both carried in the
  `Context`:

    * `seen` — the pages that produced the body being expanded, the host first.
      A page already on that list is a ring, and rings are where the mirror stops.
    * `depth` — a budget of five, deep enough for the fragments people build out
      of fragments and shallow enough that a chain nobody meant to write stops
      being read.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @max_depth 5

  @typedoc "Why an include was not read any further."
  @type limit :: :itself | :too_deep

  @doc """
  The included body, expanded as `page`'s own, or the reason it was not.
  """
  @spec expand(String.t() | nil, Context.t(), ConfluencePhxMirror.Mirror.Page.t() | map()) ::
          {:ok, [Floki.html_node()]} | {:limit, limit()}
  def expand(html, %Context{} = context, page) do
    cond do
      page.id in context.seen ->
        {:limit, :itself}

      context.depth >= @max_depth ->
        {:limit, :too_deep}

      true ->
        {:ok,
         html
         |> to_string()
         |> DynamicContent.expand(nested(context, page))
         |> Floki.parse_fragment!()}
    end
  end

  defp nested(context, page) do
    %{
      space: page.space,
      page: page,
      source: context.source,
      depth: context.depth + 1,
      seen: [page.id | context.seen]
    }
  end

  @doc "What to say instead of the body, when there is no body to read."
  @spec notice(limit()) :: [Floki.html_node()]
  def notice(:itself),
    do: [Nodes.notice("This page includes itself here, which the mirror stops at this point.")]

  def notice(:too_deep),
    do: [Nodes.notice("This page is included too deeply to read any further.")]
end
