defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.LabelsList do
  @moduledoc """
  *Labels list*: the labels a space's pages carry, most used first.

      <div class="mirror-macro" data-macro="labels-list" data-space="ENG"></div>

  Confluence resolves this in the reader's browser and leaves the macro
  unexpanded in `export_view`, so a page carrying it used to show the
  unknown-macro widget. What the macro lists is in the mirror's own tables — a
  label hangs off the pages carrying it — so the answer is drawn here instead.

  The count beside each label is pages, not "pages plus attachments": it is the
  one number the mirror can state without guessing. A label that only a page the
  host's readers may not open carries is neither listed nor counted, because the
  port narrows before anything is counted.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case context.source.labels(context.page, space(attrs),
           limit: Attributes.int(attrs, "limit", 30, 1..200)
         ) do
      {:ok, []} ->
        [Nodes.empty("No page in this space carries a label yet.")]

      {:ok, labels} ->
        [Nodes.heading("Labels"), Nodes.label_list(labels)]

      {:error, :too_large} ->
        [Nodes.notice("This space is too large to list its labels in one pass.")]
    end
  end

  defp space(attrs), do: Map.get(attrs, "space")
end
