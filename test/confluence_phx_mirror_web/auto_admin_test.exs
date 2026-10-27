defmodule ConfluencePhxMirrorWeb.AutoAdminTest do
  @moduledoc """
  `MIRROR_AUTO_ADMIN`: the development convenience that makes an anonymous
  visitor the bootstrap administrator. A production release refuses to start
  with it (`Config.IdentityGuard`), so it is off in `config/test.exs` and this
  file is the only place that turns it on — every other test signs in the
  account it needs, which is what keeps the suite free of global state.

  `async: false` is the point: this is the one file that deliberately changes a
  deployment flag for the whole node.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Mirror

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  test "an enabled deployment opens the admin screens to a visitor", %{conn: conn} do
    Application.put_env(:confluence_phx_mirror, :auto_admin, true)

    assert conn |> get(~p"/admin") |> html_response(200)
  end

  test "a deployment without it sends the visitor to sign in", %{conn: conn} do
    assert conn |> get(~p"/admin") |> redirected_to() == "/session"
  end

  test "the sign-in page says when nobody has to sign in", %{conn: conn} do
    Application.put_env(:confluence_phx_mirror, :auto_admin, true)

    assert conn |> get(~p"/session") |> html_response(200) =~ "An administrator is assumed"
  end

  test "and stays quiet about it in a deployment that needs the sign-in", %{conn: conn} do
    refute conn |> get(~p"/session") |> html_response(200) =~ "Development mode"
  end

  test "the first request of a browser is answered as the administrator everywhere", %{conn: conn} do
    Application.put_env(:confluence_phx_mirror, :auto_admin, true)

    space = space_with_icon("<svg/>")

    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{subject_type: "group", subject_key: "confluence-users"}
      ])

    # No session yet: the HTML pipeline signs the visitor in, and the
    # attachments pipeline — which serves the picture beside that space — has to
    # recognise the same reader, or a first visit shows a broken image.
    assert conn |> get(~p"/spaces/#{space.key}/icon") |> response(200) == "<svg/>"
  end

  test "the swagger page names the administrator a request will be sent as", %{conn: conn} do
    Application.put_env(:confluence_phx_mirror, :auto_admin, true)

    html = conn |> get("/api/docs/swagger") |> html_response(200)

    assert html =~ "Development mode"
    assert html =~ ConfluencePhxMirror.Accounts.Admins.bootstrap_email()
  end

  defp space_with_icon(bytes) do
    space = space_fixture(%{name: "Engineering Handbook"})
    blob_key = Key.space_icon(space.key, "image/svg+xml")
    {:ok, ^blob_key} = Store.put(blob_key, bytes)

    {:ok, space} =
      Mirror.upsert_space(%{
        key: space.key,
        name: space.name,
        icon_blob_key: blob_key,
        icon_media_type: "image/svg+xml",
        icon_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
      })

    space
  end
end
