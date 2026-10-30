defmodule ConfluencePhxMirrorWeb.Admin.SiteExportLinkTest do
  @moduledoc """
  The whole-site static export is offered where an administrator looks first:
  the dashboard, after the sync actions rather than between them, because it
  starts no sync — it reads what is already mirrored and asks the server for
  nothing but the bytes.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Export.Artifact
  alias ConfluencePhxMirror.TestConfig

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})
    space_fixture(%{key: "ENG", name: "Engineering"})
    # The prepared archive is one file shared by the whole suite.
    Artifact.forget()
    on_exit(fn -> Artifact.forget() end)

    {:ok, conn: Plug.Test.init_test_session(conn, %{"user_id" => ops.id})}
  end

  test "the dashboard links to the whole-site download", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, ~s(a#export-site[href="/admin/export/site.zip"]), "Static site")
  end

  test "the link comes after both sync actions, not between them", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")
    html = render(view)

    assert [{sync_at, _}, {space_at, _}, {export_at, _}] =
             Enum.map(["Sync now", "Sync one space", "Static site"], fn label ->
               :binary.match(html, label)
             end)

    assert sync_at < space_at and space_at < export_at
  end

  test "the tooltip says what this deployment's archive holds", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin")

    assert view |> element("#export-site") |> render() =~ "personal spaces are left out"

    # The flag changes the archive, so it has to change the sentence: a tooltip
    # that states one policy while the switch is on is a lie in the one place an
    # operator looks before downloading somebody's space.
    TestConfig.put(:export_personal_spaces, true)
    {:ok, view, _html} = live(conn, ~p"/admin")

    hint = view |> element("#export-site") |> render()

    assert hint =~ "personal spaces included"
    refute hint =~ "left out"
  end

  describe "a deployment that prepares the archive" do
    setup do
      TestConfig.put(:export_prepared, true)
      :ok
    end

    test "the press starts the build, the note counts it, and the file is handed over", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin")

      # Nothing exists yet, so the press is the work — and the screen says so
      # rather than leaving an operator wondering whether it registered.
      assert has_element?(view, "button#export-site", "Prepare static site")

      view |> element("#export-site") |> render_click()

      assert has_element?(view, "button#export-site[disabled]", "Preparing…")
      assert render(view) =~ "Building the static site"
      assert render(view) =~ "Started by ops@example.com"

      wait_for_archive()
      send(view.pid, :progress)

      assert has_element?(view, "a#export-site[href='/admin/export/site.zip'][download]")
      assert view |> element("#export-site") |> render() =~ "Download"
      assert render(view) =~ "Ready:"
      assert render(view) =~ "can be resumed"
    end

    test "a build somebody else started is named, and not started twice", %{conn: conn} do
      test = self()

      # A build that does not finish until this test lets it, so the screen is
      # seen waiting rather than catching a finished file.
      Artifact.prepare(Export.site_artifact(),
        by: "boss@example.com",
        build: fn emit ->
          emit.("half")
          send(test, {:half_written, self()})
          receive do: (:carry_on -> :ok), after: (5_000 -> :never_asked)
        end
      )

      assert_receive {:half_written, builder}, 2_000

      {:ok, view, _html} = live(conn, ~p"/admin")

      assert has_element?(view, "button#export-site[disabled]", "Preparing…")
      assert render(view) =~ "Started by boss@example.com"

      send(builder, :carry_on)
      wait_for_archive()
    end
  end

  describe "the press of a download" do
    test "shuts the button until the server says the request arrived", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      # The hook sends the key and starts the download itself; the page only
      # learns that it worked from the request.
      view |> element("#export-site") |> render_hook("start_download", %{"key" => "press-1"})

      assert has_element?(view, "#export-site[aria-disabled='true']")
      assert render(view) =~ "Starting the download…"

      Artifact.begin_download("press-1")
      send(view.pid, :download_check)

      assert has_element?(view, "#export-site[aria-disabled='false']")
      assert render(view) =~ "The download started."
    end

    test "opens the button again when the download never arrives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      refute has_element?(view, "#export-site[aria-disabled='true']")

      view |> element("#export-site") |> render_hook("start_download", %{"key" => "lost-1"})

      # Fifteen seconds of silence, one 250 ms check at a time: the file is not
      # coming, and an operator has to be able to ask again.
      for _check <- 1..60, do: send(view.pid, :download_check)

      assert has_element?(view, "#export-site[aria-disabled='false']")
      assert render(view) =~ "The download did not start"
    end

    test "says nothing about a key it never received", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      view |> element("#export-site") |> render_hook("start_download", %{"key" => ""})

      refute has_element?(view, "#export-site[aria-disabled='true']")
      refute render(view) =~ "Starting the download"
    end
  end

  defp wait_for_archive do
    status =
      Enum.reduce_while(1..200, nil, fn _attempt, _waited ->
        case Artifact.status(Export.site_artifact()) do
          {:ready, _} = ready ->
            {:halt, ready}

          _not_yet ->
            Process.sleep(25)
            {:cont, nil}
        end
      end)

    assert status, "the archive was never prepared"
    status
  end
end
