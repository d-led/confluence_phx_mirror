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

  test "the footer says when that build was made", %{conn: conn} do
    administrator = user_fixture(%{role: "admin"})

    conn = Plug.Test.init_test_session(conn, %{"user_id" => administrator.id})

    # A checkout is not a build, so the suite runs without one; this puts one in
    # front of the footer and empties it again.
    BuildInfo.cache(%{BuildInfo.dev() | version: "1.2.3", built_at: "2026-11-05 06:23+01:00"})
    on_exit(fn -> BuildInfo.forget() end)

    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#build-stamp", "2026-11-05 06:23+01:00")
  end
end
