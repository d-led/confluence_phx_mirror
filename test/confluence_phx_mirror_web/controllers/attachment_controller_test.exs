defmodule ConfluencePhxMirrorWeb.AttachmentControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.PageRestriction
  alias ConfluencePhxMirror.Repo

  setup do
    demo_snapshot!()
    :ok
  end

  test "serves the mirrored bytes with media type and ETag", %{conn: conn} do
    conn = get(conn, ~p"/attachments/ENG/1002/9001/diagram.svg")

    assert conn.status == 200
    assert response(conn, 200) =~ "<svg"
    assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "inline"
    assert [etag] = get_resp_header(conn, "etag")
    assert etag =~ ~r/^"[0-9a-f]{64}"$/
  end

  test "forces a download when asked", %{conn: conn} do
    conn = get(conn, ~p"/attachments/ENG/1002/9002/architecture.csv?download=1")
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"
  end

  test "unknown attachment ids are 404", %{conn: conn} do
    conn = get(conn, ~p"/attachments/ENG/1002/999999/nope.svg")
    assert conn.status == 404
  end

  test "a mismatched filename is a 404, not a traversal", %{conn: conn} do
    conn = get(conn, ~p"/attachments/ENG/1002/9001/..%2F..%2Fetc%2Fpasswd")
    assert conn.status in [400, 404]
  end

  test "forbids script in the served bytes and caches them per reader", %{conn: conn} do
    conn = get(conn, ~p"/attachments/ENG/1002/9001/diagram.svg")

    assert get_resp_header(conn, "content-security-policy") |> hd() =~ "script-src 'none'"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=300"]
  end

  test "a reader in the page's group downloads it, an anonymous one does not", %{conn: conn} do
    restore_auto_admin()
    restrict_page_to_group(1002, "eng-readers")
    reader = reader_in_group("eng-readers")

    permitted =
      conn
      |> init_test_session(%{user_id: reader.id})
      |> get(~p"/attachments/ENG/1002/9001/diagram.svg")

    assert permitted.status == 200

    assert build_conn() |> get(~p"/attachments/ENG/1002/9001/diagram.svg") |> Map.get(:status) ==
             404
  end

  defp restrict_page_to_group(confluence_id, group) do
    {:ok, page} = Mirror.find_page(confluence_id)

    {:ok, _restriction} =
      %PageRestriction{}
      |> PageRestriction.changeset(%{page_id: page.id, subject_type: "group", subject_key: group})
      |> Repo.insert()
  end

  defp reader_in_group(group) do
    user = user_fixture()
    {:ok, user} = Accounts.update_groups(user, [group], {:system, "test"})
    user
  end

  # The suite assumes an administrator; this test needs a real reader.
  defp restore_auto_admin do
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
  end
end
