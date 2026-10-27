defmodule ConfluencePhxMirrorWeb.AdminSettingsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Settings

  setup do
    demo_snapshot!()
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "an administrator sets the theme every reader wears", %{conn: conn} do
    conn = sign_in(conn, admin_user())
    {:ok, view, html} = live(conn, ~p"/admin/settings")

    assert html =~ "Fresh blue"
    assert html =~ "Default"

    # Saving reloads the document, because the theme is an attribute of `<html>`.
    assert {:error, {:redirect, %{to: "/admin/settings"}}} =
             view |> element("#theme-form") |> render_submit(%{"theme" => "default"})

    page = conn |> get(~p"/") |> html_response(200)
    refute document_attributes(page) =~ "fresh-blue"
  end

  test "the reader keeps their variant whatever the theme is", %{conn: conn} do
    conn = sign_in(conn, admin_user())
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    view |> element("#theme-form") |> render_submit(%{"theme" => "fresh-blue"})

    html =
      conn
      |> Plug.Test.put_req_cookie("mirror_theme", "dark")
      |> get(~p"/")
      |> html_response(200)

    assert document_attributes(html) =~ ~s(data-theme="fresh-blue")
    assert document_attributes(html) =~ ~s(data-scheme="dark")
  end

  test "the page shows the configuration the mirror booted with", %{conn: conn} do
    {:ok, _view, html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    assert html =~ "Source &amp; sync"
    assert html =~ "CM_CONFLUENCE_SITE"
    assert html =~ "Storage &amp; proxy"
  end

  test "an administrator caps how often a reader may call", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    assert view
           |> element("#settings-reading")
           |> render_submit(%{
             "values" => %{
               "reader.html_limit" => "300",
               "reader.api_limit" => "",
               "reader.attachments_limit" => ""
             }
           }) =~ "Reading saved."

    assert Settings.reader_limit(:html) == 300
    assert Settings.stored("reader.api_limit") == nil
  end

  test "clearing a limit hands it back to the deployment", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    view
    |> element("#settings-reading")
    |> render_submit(%{
      "values" => %{
        "reader.html_limit" => "300",
        "reader.api_limit" => "",
        "reader.attachments_limit" => ""
      }
    })

    view
    |> element("#settings-reading")
    |> render_submit(%{
      "values" => %{
        "reader.html_limit" => "",
        "reader.api_limit" => "",
        "reader.attachments_limit" => ""
      }
    })

    assert Settings.stored("reader.html_limit") == nil
    assert Settings.reader_limit(:html) == Settings.default("reader.html_limit")
  end

  test "a limit that is not a number saves nothing at all", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    html =
      view
      |> element("#settings-reading")
      |> render_submit(%{
        "values" => %{
          "reader.html_limit" => "300",
          "reader.api_limit" => "lots",
          "reader.attachments_limit" => ""
        }
      })

    assert html =~ "Nothing was saved"
    assert Settings.stored("reader.html_limit") == nil
  end

  test "an unchecked box turns notification mail off", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    # A cleared checkbox posts nothing at all, which is an explicit "off".
    assert view
           |> element("#settings-notifications")
           |> render_submit(%{"values" => %{"notifications.digest_hour_utc" => "9"}}) =~
             "Notifications saved."

    refute Settings.notifications_enabled?()
    assert Settings.digest_hour_utc() == 9
  end

  test "an hour that cannot exist saves nothing at all", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    html =
      view
      |> element("#settings-notifications")
      |> render_submit(%{
        "values" => %{
          "notifications.enabled" => "true",
          "notifications.digest_hour_utc" => "24"
        }
      })

    assert html =~ "Nothing was saved"
    assert Settings.stored("notifications.digest_hour_utc") == nil
  end

  test "every group the catalogue marks for this screen has a form", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    assert has_element?(view, "#theme-form")
    assert has_element?(view, "#settings-reading")
    assert has_element?(view, "#settings-sync")
    assert has_element?(view, "#settings-notifications")
    assert has_element?(view, "#settings-operations")

    # A setting declared after the first release gets a control without the
    # screen naming it.
    assert has_element?(view, ~s([id="setting-search.page_size-input"]))

    # The webhook switches live on their own screen, where the cost is spelled
    # out; this page must not grow a second editor for them.
    refute has_element?(view, "#settings-webhooks")
  end

  test "a group hands every field back to the deployment at once", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    view
    |> element("#settings-reading")
    |> render_submit(%{"values" => %{"reader.html_limit" => "300"}})

    assert Settings.stored("reader.html_limit") == 300

    assert view
           |> element("#settings-reading-defaults")
           |> render_click() =~ "Reading follows the deployment"

    assert Settings.stored("reader.html_limit") == nil
  end

  test "a member is sent home, not shown the page", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} =
             live(
               sign_in(conn, user_fixture(%{email: "member@example.com"})),
               ~p"/admin/settings"
             )
  end

  test "an anonymous reader is sent to sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/session"}}} = live(conn, ~p"/admin/settings")
  end

  defp admin_user do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
