defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Include do
  @moduledoc """
  *Include Page*: another page's body, in place.

      <div class="mirror-macro" data-macro="include" data-page="Architecture Overview"></div>
      <div class="mirror-macro" data-macro="include" data-page="ENG/Runbooks"></div>

  This is how pages are built out of fragments, and the fragment is already in the
  mirror: an include is one query (`Source.page_by_title/2`) and no parsing of the
  page it sits on. The body arrives expanded, so the included page's own macros —
  its table of contents, its listings — answer as that page, not as the host.

  The audience rule is the port's: the body is baked into this page for every
  reader of it, so the page named may only be one whose readers are at least as
  wide as this page's. A restricted page named by an open one is not included,
  and an include that loops or nests too deep is stopped by `Included`.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Included, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case title(attrs) do
      "" -> [Nodes.empty("This macro names no page, so there is nothing to include.")]
      title -> include(title, context)
    end
  end

  defp include(title, context) do
    with {:ok, page} <- context.source.page_by_title(context.page, title),
         {:ok, nodes} <- Included.expand(page.body_export, context, page) do
      nodes
    else
      :error ->
        [Nodes.notice("The page this macro includes is not in the mirror, or not readable here.")]

      {:limit, reason} ->
        Included.notice(reason)
    end
  end

  defp title(attrs), do: attrs |> Map.get("page", "") |> String.trim()
end
