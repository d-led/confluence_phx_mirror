defmodule ConfluencePhxMirrorWeb.AdminBroadcastTest do
  @moduledoc """
  The topics that carry an administrator's material have no audience of their own.

  `Phoenix.PubSub` delivers to whoever subscribed, and nothing in it asks who
  that is: `"audit"` carries every entry with the actor's e-mail in it,
  `"sync:log"` carries every call the mirror makes to the site, `"reconcile_run"`
  carries what a full re-read is doing. What keeps them off a reader's screen is
  therefore the screens themselves — the only subscriptions are in the
  administration screens, and the `:admin` mount hook refuses everybody else
  before a screen gets as far as subscribing.

  Both halves of that are held here: every screen the router mounts under
  `/admin` refuses an anonymous visitor and a member, and no screen a reader
  opens names an administrator's topic at all.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirrorWeb.Router

  # The BEAM dashboard's pages have their own matrix in `admin_access_test.exs`,
  # which walks every page LiveDashboard serves rather than only the way in.
  @runtime_prefix "/admin/runtime"

  describe "a screen that streams an administrator's material" do
    # The four screens that hold a subscription, named: the matrix below reads
    # the router, and a matrix that read nothing would pass for the wrong reason.
    test "is one of the screens the router mounts under /admin" do
      screens = admin_screens()

      for screen <- ["/admin/audit", "/admin/sync-log", "/admin/upstream", "/admin/users"] do
        assert screen in screens
      end
    end

    test "is closed to an anonymous visitor", %{conn: conn} do
      for path <- admin_screens() do
        assert {:error, {:redirect, %{to: "/session"}}} = live(conn, path),
               "expected #{path} to require signing in"
      end
    end

    test "is closed to a member", %{conn: conn} do
      conn = log_in(conn, user_fixture())

      for path <- admin_screens() do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, path),
               "expected #{path} to refuse a plain member"
      end
    end
  end

  test "no screen a reader opens names an administrator's topic" do
    topics = ["Audit.topic", "Log.topic", "ReconcileRun.topic"]

    reader_screens =
      "lib/confluence_phx_mirror_web/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/live/admin/"))

    for file <- reader_screens,
        topic <- topics,
        String.contains?(File.read!(file), topic) do
      flunk("#{file} names #{topic}: what an administrator watches belongs under live/admin")
    end
  end

  # Every screen the router mounts under `/admin`. A route's params get a value
  # the mount hook never reads: the guard is the question, not what the screen
  # would find behind it.
  defp admin_screens do
    for %{path: path, plug: Phoenix.LiveView.Plug} <- Router.__routes__(),
        String.starts_with?(path, "/admin"),
        not String.starts_with?(path, @runtime_prefix),
        do: with_params(path)
  end

  defp with_params(path) do
    path
    |> String.replace(":space_key", "ENG")
    |> String.replace(":page_id", "1002")
  end
end
