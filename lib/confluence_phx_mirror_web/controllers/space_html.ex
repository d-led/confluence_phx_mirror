defmodule ConfluencePhxMirrorWeb.SpaceHTML do
  @moduledoc "Templates for the space directory and the per-space catalogs."

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.Time

  embed_templates "space_html/*"
end
