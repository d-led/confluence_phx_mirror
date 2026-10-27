defmodule ConfluencePhxMirrorWeb.ApiSpacesTest do
  @moduledoc """
  The two writes the API accepts about a space: adding one to the whitelist a
  run imports, and taking one back out. Both are an administrator's, and
  neither pretends to have changed more than it did.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

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

  test "an administrator adds a space to the whitelist", %{conn: conn} do
    configured_spaces(["ENG"])

    conn = conn |> as_admin() |> post(~p"/api/v1/spaces", %{"key" => "prod"})

    assert %{"key" => "PROD", "every_space" => false, "keys" => keys} =
             json_response(conn, 201)

    assert keys == ["ENG", "PROD"]
    assert SpaceScope.wanted() == ["ENG", "PROD"]
  end

  test "a mirror that imports every space refuses to be narrowed by one key", %{conn: conn} do
    conn = conn |> as_admin() |> post(~p"/api/v1/spaces", %{"key" => "ENG"})

    assert %{"error" => "imports_every_space"} = json_response(conn, 409)
    assert SpaceScope.wanted() == :all
  end

  test "adding nothing is a refusal, not an empty key", %{conn: conn} do
    configured_spaces(["ENG"])

    conn = conn |> as_admin() |> post(~p"/api/v1/spaces", %{})

    assert %{"error" => "not_saved"} = json_response(conn, 422)
    assert SpaceScope.added() == []
  end

  test "a reader who is not an administrator cannot change the whitelist", %{conn: conn} do
    configured_spaces(["ENG"])

    conn =
      conn
      |> init_test_session(user_id: user_fixture().id)
      |> post(~p"/api/v1/spaces", %{"key" => "PROD"})

    assert %{"error" => "not_authorized"} = json_response(conn, 403)
    assert SpaceScope.added() == []
  end

  test "removing a space says how much the next run will trash", %{conn: conn} do
    configured_spaces(["ENG"])
    SpaceScope.add("PROD", {:system, "test"})

    conn = conn |> as_admin() |> delete(~p"/api/v1/spaces/PROD")

    assert %{
             "key" => "PROD",
             "removed" => true,
             "pages_awaiting_trash" => pages,
             "keys" => ["ENG"]
           } = json_response(conn, 200)

    assert pages > 0
    assert SpaceScope.wanted() == ["ENG"]
  end

  test "a key the deployment names is not removed by asking", %{conn: conn} do
    configured_spaces(["ENG"])

    conn = conn |> as_admin() |> delete(~p"/api/v1/spaces/eng")

    assert %{"key" => "ENG", "removed" => false, "keys" => ["ENG"]} = json_response(conn, 200)
    assert SpaceScope.wanted() == ["ENG"]
  end

  defp as_admin(conn) do
    previous = Application.get_env(:confluence_phx_mirror, :admins)
    Application.put_env(:confluence_phx_mirror, :admins, ["ops@example.com"])
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :admins, previous) end)

    user = user_fixture(%{email: "ops@example.com", role: "member"})
    init_test_session(conn, user_id: user.id)
  end

  defp configured_spaces(spaces) do
    previous = Application.get_env(:confluence_phx_mirror, HttpSource)
    Application.put_env(:confluence_phx_mirror, HttpSource, spaces: spaces)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, HttpSource, previous) end)
  end
end
