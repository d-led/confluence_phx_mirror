defmodule ConfluencePhxMirrorWeb.Admin.SettingsController do
  @moduledoc """
  The configuration this mirror booted with.

  A controller rather than a LiveView on purpose: every value on the page is
  fixed at boot, so there is nothing to subscribe to. The screens that watch
  something change are the live ones.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirrorWeb.Admin.Settings

  def index(conn, _params) do
    user = Scope.user(Scope.from_assigns(conn.assigns))

    render(conn, :settings,
      page_title: "Settings",
      sections: Settings.sections(user)
    )
  end
end
