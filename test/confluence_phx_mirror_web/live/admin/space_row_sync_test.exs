defmodule ConfluencePhxMirrorWeb.AdminSpaceRowSyncTest do
  @moduledoc """
  The Sync button on a row of the spaces list.

  It is the same job the overview's "Sync one space" queues, reached from the
  list an administrator is already reading — so what matters is that the row's
  key is the one that gets queued, and that the press says what happened. A
  button that queues nothing looks exactly like one that works, which is why
  this is asserted against the jobs table rather than against the screen alone.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings
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

  test "a row's Sync queues that space, and says so", %{conn: conn} do
    configured_spaces(["ENG"])
    {:ok, view, _html} = live(sign_in(conn, admin_user()), ~p"/admin/spaces")

    view |> element("#sync-space-ENG") |> render_click()

    assert queued_space_keys() == ["ENG"]
    assert render(view) =~ "A refresh of ENG is queued."
  end

  defp queued_space_keys do
    Repo.all(from j in Oban.Job, where: j.queue == "sync", select: j.args["space_key"])
  end

  defp configured_spaces(spaces), do: TestConfig.put(HttpSource, spaces: spaces)

  defp admin_user do
    TestConfig.put(:admins, ["ops@example.com"])

    user_fixture(%{email: "ops@example.com", role: "member"})
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{"user_id" => user.id})
end
