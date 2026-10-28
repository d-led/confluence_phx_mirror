defmodule ConfluencePhxMirror.Sync.DynamicContent.Registry do
  @moduledoc """
  Which macro name is drawn by which renderer — the one list to extend.

  A macro is available to a page the moment its name is here and its module
  implements `ConfluencePhxMirror.Sync.DynamicContent.Renderer`. Adding one is a
  module, a test and a line in this map; nothing is discovered at runtime, so
  what the mirror can draw is readable in one place and dialyzer can see it.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.Renderers

  @renderers %{
    "children" => Renderers.Children,
    "content-by-label" => Renderers.ContentByLabel,
    "page-properties-report" => Renderers.PagePropertiesReport,
    "toc" => Renderers.Toc
  }

  @doc "The renderer that draws `name`, or `:error` for a macro the mirror lacks."
  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name), do: Map.fetch(@renderers, name)

  @doc "Every macro the mirror draws, sorted, for docs and refusal messages."
  @spec macros() :: [String.t()]
  def macros, do: @renderers |> Map.keys() |> Enum.sort()

  @doc "The whole map, name to renderer."
  @spec all() :: %{optional(String.t()) => module()}
  def all, do: @renderers
end
