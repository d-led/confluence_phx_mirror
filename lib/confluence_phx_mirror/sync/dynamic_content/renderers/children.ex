defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Children do
  @moduledoc """
  *Children Display*: the pages directly below this one.

      <div class="mirror-macro" data-macro="children" data-limit="50"></div>

  The tree is in the mirror (`pages.parent_id`), so the list is one query. A
  child the readers of this page may not open is left out: the macro is resolved
  once for every reader, and a child list is exactly where a restriction would
  leak if it were resolved naively.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    pages =
      context.source.children(context.page, context.page,
        limit: Attributes.int(attrs, "limit", 50, 1..200)
      )

    case pages do
      [] -> [Nodes.empty("This page has no child pages.")]
      pages -> [Nodes.heading("Child pages"), Nodes.page_list(pages)]
    end
  end
end
