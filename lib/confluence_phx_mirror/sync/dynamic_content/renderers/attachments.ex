defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Attachments do
  @moduledoc """
  *Attachments*: the files on the page carrying the macro.

      <div class="mirror-macro" data-macro="attachments"></div>

  Every file a sync downloaded is in the mirror's blob store and has a reader
  route, so the list is one query and each name is a working download — the same
  files the rail shows, in the place the page itself asks for them.

  The macro lists the page it sits on, never another: a file is exactly as
  readable as the page holding it, so there is no audience to reconcile.

  The space key comes from the context, not from the page: a run holds a page
  whose space association is not loaded while it writes it.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @impl true
  def render(_attrs, %Context{} = context) do
    case context.source.attachments(context.page) do
      [] ->
        [Nodes.empty("This page has no attachments.")]

      files ->
        [Nodes.heading("Attachments"), Nodes.file_list(context.space.key, context.page, files)]
    end
  end
end
