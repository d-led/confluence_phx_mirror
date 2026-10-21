defmodule ConfluencePhxMirrorWeb.AttachmentControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

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
end
