defmodule ConfluencePhxMirrorWeb.AdminSpacesLiveTest do
  @moduledoc """
  The screen that widens the whitelist: what it offers, what it refuses, and
  what it leaves to the environment.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync.SpaceScope

  setup do
    demo_snapshot!()

    on_exit(fn ->
      # The setting cache outlives the sandbox transaction that held the row.
      Settings.forget()
    end)

    Settings.reload()
    :ok
  end

  test "a mirror that imports everything says there is nothing to add", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    assert has_element?(view, "#every-space")
    refute has_element?(view, "#add-space")
  end

  test "what is typed is answered from the site's listing, minus what it imports", %{conn: conn} do
    configured_spaces(["ENG"])
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    view |> element("#add-space-key") |> render_change(%{"key" => "prod"})

    assert has_element?(view, "[id=\"add-space-suggestions-PROD\"]")
    refute has_element?(view, "[id=\"add-space-suggestions-ENG\"]")
  end

  test "picking a suggested space adds it", %{conn: conn} do
    configured_spaces(["ENG"])
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    view |> element("#add-space-key") |> render_change(%{"key" => "pro"})
    html = view |> element(~s([id="add-space-suggestions-PROD"])) |> render_click()

    assert html =~ "PROD added"
    assert SpaceScope.wanted() == ["ENG", "PROD"]
    assert has_element?(view, "#whitelist-PROD")
  end

  test "adding a space widens the whitelist", %{conn: conn} do
    configured_spaces(["ENG"])
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    html = view |> element("#add-space") |> render_submit(%{"key" => "PROD"})

    assert html =~ "PROD added"
    assert SpaceScope.wanted() == ["ENG", "PROD"]
    assert has_element?(view, "#whitelist-PROD")
  end

  test "removing an added space takes it back out, leaving the environment's", %{conn: conn} do
    configured_spaces(["ENG"])
    SpaceScope.add("PROD", {:system, "test"})

    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")
    assert has_element?(view, "#whitelist-PROD")

    view |> element("#whitelist-PROD button") |> render_click()

    refute has_element?(view, "#whitelist-PROD")
    assert SpaceScope.wanted() == ["ENG"]
  end

  test "naming a key on a mirror that imports everything is refused", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    html = render_submit(view, "add", %{"key" => "ENG"})

    assert html =~ "Set CM_SPACES first"
    assert SpaceScope.wanted() == :all
  end

  test "the mirrored list pages through every space instead of cutting off", %{conn: conn} do
    for index <- 1..26 do
      space = space_fixture(%{key: "PAGED#{index}"})
      page_fixture(space, %{title: "Paged #{index}"})
    end

    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    assert view |> element("#mirrored-pager") |> render() =~ "page 1 of"
    assert has_element?(view, ~s(#mirrored-pager a[href="/admin/spaces?page=2"]))

    {:ok, second, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces?page=2")

    assert second |> element("#mirrored-pager") |> render() =~ "page 2 of 2"
  end

  test "the filter runs over every mirrored space, not the page on screen", %{conn: conn} do
    for key <- ~w(FILTERONE FILTERTWO OTHERSPACE) do
      page_fixture(space_fixture(%{key: key}), %{title: "A page of #{key}"})
    end

    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    view |> render_change("filter", %{"q" => "filtert"})

    assert_patch(view, ~p"/admin/spaces?page=1&q=filtert")

    html = view |> element("#mirrored-filter") |> render()
    assert html =~ "filtert"
    refute render(view) =~ "OTHERSPACE"
  end

  test "a filter that matches nothing says so, and names the filter", %{conn: conn} do
    page_fixture(space_fixture(%{key: "SOLO"}), %{title: "Only page"})

    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces?q=nothing-matches")

    assert has_element?(view, "#no-mirrored-match")
    assert view |> element("#no-mirrored-match") |> render() =~ "nothing-matches"
  end

  defp configured_spaces(spaces) do
    previous = Application.get_env(:confluence_phx_mirror, HttpSource)
    Application.put_env(:confluence_phx_mirror, HttpSource, spaces: spaces)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, HttpSource, previous) end)
  end

  defp admin_user do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
