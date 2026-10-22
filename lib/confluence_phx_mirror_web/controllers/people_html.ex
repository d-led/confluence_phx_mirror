defmodule ConfluencePhxMirrorWeb.PeopleHTML do
  @moduledoc "Templates for the people directory."

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.Time

  embed_templates "people_html/*"
end
