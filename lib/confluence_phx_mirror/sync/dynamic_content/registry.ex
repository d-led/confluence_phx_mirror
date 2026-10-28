defmodule ConfluencePhxMirror.Sync.DynamicContent.Registry do
  @moduledoc """
  Which macro name is drawn by which renderer — the one list to extend.

  A macro is available to a page the moment its name is here and its module
  implements `ConfluencePhxMirror.Sync.DynamicContent.Renderer`. Adding one is a
  module, a test and a line in this map; nothing is discovered at runtime, so
  what the mirror can draw is readable in one place and dialyzer can see it.

  The names are Confluence's own `ac:name` keys from the storage format, not
  names we invented: a page records its macros as
  `<ac:structured-macro ac:name="detailssummary">`, so that is the word a marker
  has to carry for the mirror to recognise what a page asked for.

  `@aliases` covers the rest — the friendly name a person would write, and the
  spellings Confluence has used across versions. An alias resolves to the same
  renderer, and `macros/0` lists only the canonical names, so documentation and
  refusals stay unambiguous.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.Renderers

  @renderers %{
    "attachments" => Renderers.Attachments,
    "blog-posts" => Renderers.BlogPosts,
    "children" => Renderers.Children,
    "content-by-label" => Renderers.ContentByLabel,
    "content-report-table" => Renderers.ContentReportTable,
    "contributors" => Renderers.Contributors,
    "detailssummary" => Renderers.PagePropertiesReport,
    "excerpt-include" => Renderers.ExcerptInclude,
    "include" => Renderers.Include,
    "pagetree" => Renderers.PageTree,
    "recently-updated" => Renderers.RecentlyUpdated,
    "toc" => Renderers.Toc
  }

  # What the same macro is called elsewhere. The Page Properties Report is the
  # one that catches people out: Confluence's key is `detailssummary`, and
  # nothing in its UI says so.
  @aliases %{
    "page-properties-report" => "detailssummary",
    "table-of-contents" => "toc"
  }

  @doc "The renderer that draws `name`, or `:error` for a macro the mirror lacks."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name), do: Map.fetch(@renderers, canonical(name))

  @doc """
  The canonical name for `name`: itself, or the macro it is another spelling of.

      iex> canonical("page-properties-report")
      "detailssummary"
  """
  @spec canonical(String.t()) :: String.t()
  def canonical(name), do: Map.get(@aliases, name, name)

  @doc "Every macro the mirror draws, by its Confluence name, sorted."
  @spec macros() :: [String.t()]
  def macros, do: @renderers |> Map.keys() |> Enum.sort()

  @doc "Every name the mirror answers to, canonical and alias, sorted."
  @spec names() :: [String.t()]
  def names, do: Enum.sort(macros() ++ Map.keys(@aliases))

  @doc "The whole map, canonical name to renderer."
  @spec all() :: %{optional(String.t()) => module()}
  def all, do: @renderers
end
