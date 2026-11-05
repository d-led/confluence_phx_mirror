defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.LabelsList do
  @moduledoc """
  *Labels list*: a space's labels, in the four alphabetical columns Confluence's
  own macro draws.

      <div class="mirror-macro" data-macro="labels-list" data-space="ENG"></div>

  Confluence resolves this in the reader's browser and leaves the macro
  unexpanded in `export_view`, so a page carrying it used to show the
  unknown-macro widget. What the macro lists is in the mirror's own tables — a
  label hangs off the pages carrying it — so the answer is drawn here instead.

  The grouping is Confluence's: *A–G*, *H–N*, *O–R*, *S–Z*, each a column, and a
  column with nothing in it is not drawn. A label that only a page the host's
  readers may not open carries is not named, because the port narrows before
  anything is listed.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case context.source.labels(context.page, space(attrs), []) do
      {:ok, []} ->
        [Nodes.empty("No page in this space carries a label yet.")]

      {:ok, labels} ->
        [Nodes.label_groups(labels)]

      {:error, :too_large} ->
        [Nodes.notice("This space is too large to list its labels in one pass.")]
    end
  end

  defp space(attrs), do: Map.get(attrs, "space")
end
