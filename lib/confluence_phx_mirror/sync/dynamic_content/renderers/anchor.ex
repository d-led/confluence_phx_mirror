defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Anchor do
  @moduledoc """
  *Anchor*: a name inside the page that a link can point at.

      <ac:structured-macro ac:name="anchor" ac:schema-version="1">
        <ac:parameter ac:name="">section-two</ac:parameter>
      </ac:structured-macro>

  The macro carries no content and draws nothing; it records a name so that
  `#section-two` lands here. Confluence writes the name in a parameter with no
  name of its own — the macro is about exactly one thing — which `Marker` reads
  as the marker's `data-name`.

  `export_view` leaves a picture of the macro, so the name is only in the
  storage: without this, every link to an anchor on a mirrored page skipped to
  the top of the document.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @impl true
  def render(attrs, %Context{}) do
    case attrs |> Map.get("name", "") |> String.trim() do
      "" -> [Nodes.notice("This anchor names nothing, so nothing can link to it.")]
      name -> [{"a", [{"id", name}, {"class", "mirror-anchor"}], []}]
    end
  end
end
