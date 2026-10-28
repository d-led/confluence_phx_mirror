defmodule ConfluencePhxMirrorWeb.AdminSettingsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.TestConfig

  setup do
    demo_snapshot!()
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "typing a space key offers the spaces the site lists", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    view
    |> element(~s([id="setting-sync.spaces-input"]))
    |> render_change(%{"values" => %{"sync.spaces" => "eng"}})

    assert has_element?(view, ~s([id="sync.spaces-suggestions-ENG"]))
  end

  test "picking a suggested space writes it into the field, then saves it", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    view
    |> element(~s([id="setting-sync.spaces-input"]))
    |> render_change(%{"values" => %{"sync.spaces" => "PROD, eng"}})

    view |> element(~s([id="sync.spaces-suggestions-ENG"])) |> render_click()

    assert has_element?(view, ~s(input#setting-sync\\.spaces-input[value="PROD, ENG"]))

    view
    |> element("#settings-sync")
    |> render_submit(%{"values" => %{"sync.spaces" => "PROD, ENG"}})

    assert Settings.stored("sync.spaces") == ["PROD", "ENG"]
  end

  test "a boolean is one click, not two", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

    # The box sits inside its label, so the label must not also point at it:
    # a `for` there delivers the click twice and lands back where it started.
    assert has_element?(view, ~s([id="setting-notifications.enabled-input"]))
    refute has_element?(view, ~s(label[for="setting-notifications.enabled-input"]))
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

  describe "the filter" do
    test "keeps the rows that match and takes the others out of sight", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings?q=concurrency")

      assert shown?(view, "setting-sync.concurrency")
      refute shown?(view, "setting-sync.lookback_seconds")
      assert has_element?(view, "#settings-shown", "1")
    end

    test "asks for every word at once", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings?q=sync%20theme")

      # "sync" is one row's group and "theme" another's control — no single
      # answer says both, so the page says so instead of showing either.
      refute shown?(view, "setting-sync.concurrency")
      assert has_element?(view, "#settings-no-match")
    end

    test "hides a row without taking its field out of the group's form", %{conn: conn} do
      {:ok, _applied} =
        Settings.update(%{"notifications.enabled" => false}, {:system, "an administrator"})

      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings?q=digest")

      refute shown?(view, "setting-notifications.enabled")
      assert has_element?(view, ~s([id="setting-notifications.enabled-input"]))

      view
      |> element("#settings-notifications")
      |> render_submit(%{"values" => %{"notifications.enabled" => "on"}})

      # The row out of sight kept its value: a group is one transaction, and a
      # field the filter took away must not read as "cleared".
      assert Settings.notifications_enabled?()
    end

    test "narrows the boot configuration with the same words", %{conn: conn} do
      {:ok, _view, html} =
        live(sign_in(conn, admin_user()), ~p"/admin/settings?q=CM_REQUESTS_PER_SECOND")

      assert html =~ "Requests per second"
      refute html =~ "Storage &amp; proxy"
      refute html =~ "CM_ADMINS"
    end

    test "the filter lives in the address, so the question can be shared", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/settings")

      view
      |> element("#settings-filter")
      |> render_change(%{"q" => "digest"})

      assert_patch(view, "/admin/settings?q=digest")
      assert shown?(view, "setting-notifications.digest_hour_utc")
    end
  end

  # A row the filter hides is rendered with `hidden` on it rather than left out:
  # that is what keeps its field in the form (see the test above).
  defp shown?(view, id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([id="#{id}"]))
    |> LazyHTML.attribute("class")
    |> Enum.any?(fn classes -> not (classes |> String.split() |> Enum.member?("hidden")) end)
  end

  defp admin_user do
    TestConfig.put(:admins, ["ops@example.com"])

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
