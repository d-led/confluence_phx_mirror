defmodule ConfluencePhxMirrorWeb.PageHTML do
  @moduledoc "Templates for the reader-facing mirror."

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents
  import ConfluencePhxMirrorWeb.UIComponents

  alias ConfluencePhxMirrorWeb.Time

  embed_templates "page_html/*"
end
