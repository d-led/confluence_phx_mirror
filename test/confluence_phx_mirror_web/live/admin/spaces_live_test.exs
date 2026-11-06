defmodule ConfluencePhxMirrorWeb.AdminSpacesLiveTest do
  @moduledoc """
  The screen that widens the whitelist: what it offers, what it refuses, and
  what it leaves to the environment.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sync.SpaceScope
  alias ConfluencePhxMirror.TestConfig

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

  test "a mirrored row opens the space it names, and refreshes only that one", %{conn: conn} do
    page_fixture(space_fixture(%{key: "ENG", name: "Engineering"}), %{title: "A page of ENG"})
    page_fixture(space_fixture(%{key: "OPS", name: "Operations"}), %{title: "A page of OPS"})

    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    assert has_element?(view, ~s(a[href="/spaces/ENG"]), "Engineering")

    view |> element("#sync-space-ENG") |> render_click()

    assert queued_space_keys() == ["ENG"]
  end

  describe "asking the site again" do
    test "the listing is what the site answers now, and the screen says it asked", %{conn: conn} do
      configured_spaces(["ENG"])
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

      html = view |> element("#refresh-spaces") |> render_click()

      assert html =~ "Confluence was asked again."
    end

    # A mirror can be paused from another tab while this screen is open, and the
    # button in front of the reader is the one drawn before the pause. Asking
    # then is answered without a call, and the sentence says how to resume.
    test "a mirror paused after the screen opened is not asked", %{conn: conn} do
      configured_spaces(["ENG"])
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

      {:ok, _applied} = Settings.update(%{"sync.paused" => true}, {:system, "test"})

      html = view |> element("#refresh-spaces") |> render_click()

      assert html =~ "Confluence calls are paused, so nothing was asked."
    end

    test "a site that does not answer is named, not hidden", %{conn: conn} do
      configured_spaces(["ENG"])
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

      html =
        TestConfig.with([source: ConfluencePhxMirrorWeb.AdminSpacesLiveTest.RefusingSource], fn ->
          view |> element("#refresh-spaces") |> render_click()
        end)

      assert html =~ "Confluence did not answer: :timeout"
    end
  end

  defp queued_space_keys do
    Repo.all(from j in Oban.Job, where: j.queue == "sync", select: j.args["space_key"])
  end

  defp configured_spaces(spaces) do
    TestConfig.put(HttpSource, spaces: spaces)
  end

  defp admin_user do
    TestConfig.put(:admins, ["ops@example.com"])

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end

# A source that refuses the space listing, for the sentence the screen has for a
# site that did not answer.
defmodule ConfluencePhxMirrorWeb.AdminSpacesLiveTest.RefusingSource do
  def kind, do: :live

  def spaces(_opts), do: {:error, :timeout}
end
