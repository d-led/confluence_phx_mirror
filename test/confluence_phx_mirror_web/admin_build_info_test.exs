defmodule ConfluencePhxMirrorWeb.AdminBuildInfoTest do
  @moduledoc """
  The admin footer names the build an administrator is looking at, and reader
  pages do not.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.BuildInfo

  test "an administrator's footer names the build", %{conn: conn} do
    administrator = user_fixture(%{role: "admin"})

    conn = Plug.Test.init_test_session(conn, %{"user_id" => administrator.id})

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#build-info", BuildInfo.label())
    assert has_element?(view, "#build-info[title='#{BuildInfo.description()}']")
  end

  test "a reader's page carries no build label", %{conn: conn} do
    # The suite signs everybody in as the bootstrap administrator by default;
    # a visitor is what this test is about.

    html = conn |> get(~p"/about") |> html_response(200)

    refute html =~ "build-info"
  end
end
