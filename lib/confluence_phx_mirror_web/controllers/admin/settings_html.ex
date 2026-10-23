defmodule ConfluencePhxMirrorWeb.Admin.SettingsHTML do
  @moduledoc "Templates for the admin settings page."

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.AdminComponents

  embed_templates "settings_html/*"
end
