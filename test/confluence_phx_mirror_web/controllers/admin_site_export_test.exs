defmodule ConfluencePhxMirrorWeb.AdminSiteExportTest do
  @moduledoc """
  The whole mirror as one static site: an administrator's download, and nobody
  else's.

  A reader's own copy of one space lives on that space (`/spaces/:key/site.zip`).
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)

    demo_snapshot!()
    :ok
  end

  describe "who may download it" do
    test "a member is refused", %{conn: conn} do
      member = user_fixture(%{email: "member@example.com"})

      assert conn
             |> signed_in(member)
             |> get(~p"/admin/export/site.zip")
             |> response(403)
    end

    test "an anonymous reader is refused", %{conn: conn} do
      assert conn |> get(~p"/admin/export/site.zip") |> response(403)
    end
  end

  describe "the download" do
    test "is a ZIP named after the site", %{conn: conn} do
      conn =
        conn
        |> signed_in(user_fixture(%{email: "ops@example.com", role: "admin"}))
        |> get(~p"/admin/export/site.zip")

      assert conn.status == 200
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/zip"
      assert conn |> get_resp_header("content-disposition") |> hd() =~ "site_"
    end
  end

  defp signed_in(conn, user), do: init_test_session(conn, %{"user_id" => user.id})
end
