defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.NativeEmbed do
  @moduledoc """
  *Whiteboards and Databases*: embedded content the mirror links to instead of drawing.

      <div class="mirror-macro" data-macro="native-embed:whiteboard"
           data-url="https://site/wiki/spaces/MFS/whiteboard/28344336"></div>

  Both are drawn by Confluence's own client — a whiteboard is a canvas, a
  database is a view — and neither has a representation the mirror can bake: the
  export view carries only an unknown-macro placeholder, which is why the site's
  own render shows a placeholder too. What the page does record is where the
  object lives, so the macro says what the embed is and points at it, rather
  than drawing a box that pretends the mirror has the content.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @kinds %{
    "native-embed:database" => "Database",
    "native-embed:whiteboard" => "Whiteboard"
  }

  @impl true
  def render(attrs, %Context{}) do
    case url(attrs) do
      nil ->
        [
          Nodes.notice(
            "#{kind(attrs)}: the embed names no address, so the mirror cannot link to it."
          )
        ]

      url ->
        [Nodes.notice("#{kind(attrs)} — drawn in Confluence; open it there."), address(url)]
    end
  end

  defp address(url),
    do: {"p", [], [{"a", [{"href", url}, {"class", "mirror-dynamic-link"}], [url]}]}

  # A marker carries the macro it came from, which is the only place the kind is
  # recorded: the page writes one name for each embed.
  defp kind(attrs), do: Map.get(@kinds, Map.get(attrs, "macro"), "Embedded content")

  defp url(attrs) do
    case attrs |> Map.get("url", "") |> String.trim() do
      "" -> nil
      url -> url
    end
  end
end
