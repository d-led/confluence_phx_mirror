defmodule ConfluencePhxMirror.PauseTest do
  @moduledoc """
  "Pause Confluence calls" has to mean what it says: no run starts, no queued job
  runs, no space listing is fetched — and the screens that would otherwise say
  "sync now" say why they cannot instead.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  use Oban.Testing, repo: ConfluencePhxMirror.Repo

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.{Repo, Settings, SpaceDirectory}
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{SnapshotWorker, SyncRun}

  setup do
    Settings.reload()

    on_exit(fn ->
      # The cache outlives the sandbox transaction that held the row.
      Settings.forget()
      Settings.reload()
    end)

    :ok
  end

  describe "a paused mirror" do
    setup do
      {:ok, _applied} = Settings.update(%{"sync.paused" => true}, {:system, "test"})
      :ok
    end

    test "starts no run, and records none" do
      before = Repo.aggregate(SyncRun, :count)

      assert {:error, :paused} = Sync.run(:incremental)
      assert Repo.aggregate(SyncRun, :count) == before
    end

    test "makes a periodic job wait instead of failing it" do
      assert {:snooze, 300} = perform_job(SnapshotWorker, %{})
    end

    test "asks the site for no space listing" do
      assert {:error, :paused} = SpaceDirectory.available()
      assert {:error, :paused} = SpaceDirectory.refresh()
    end

    test "says so on the overview, with the way out", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin")

      assert has_element?(view, "#sync-paused")
      assert view |> element("#sync-paused") |> render() =~ "Resume in Settings"
    end

    test "says so on the identities screen, and offers no sync", %{conn: conn} do
      {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/identities")

      assert has_element?(view, "#sync-identities[disabled]")
      assert has_element?(view, "#identities-paused")
    end

    test "says so in the footer of a reader page", %{conn: conn} do
      assert conn |> get(~p"/") |> html_response(200) =~ "updates paused"
    end
  end

  test "resuming lets the next run start again", %{conn: _conn} do
    {:ok, _applied} = Settings.update(%{"sync.paused" => true}, {:system, "test"})
    assert {:error, :paused} = Sync.run(:incremental)

    {:ok, _applied} = Settings.update(%{"sync.paused" => false}, {:system, "test"})

    assert {:ok, %{status: "succeeded"}} = Sync.run(:incremental)
  end

  defp admin_user do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops-pause@example.com"])
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    user_fixture(%{email: "ops-pause@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
