defmodule ConfluencePhxMirrorWeb.AdminSiteExportTest do
  @moduledoc """
  The whole mirror as one static site: an administrator's download, and nobody
  else's.

  A reader's own copy of one space lives on that space (`/spaces/:key/site.zip`).
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Export.Artifact

  setup do
    demo_snapshot!()
    # The prepared archive is a file on disk that the whole suite shares, so no
    # example may find one another example left behind.
    Artifact.forget()
    on_exit(fn -> Artifact.forget() end)
    :ok
  end

  describe "who may download it" do
    test "a member is refused", %{conn: conn} do
      member = user_fixture(%{email: "member@example.com"})

      assert conn
             |> signed_in(member)
             |> get(~p"/admin/export/site.zip")
             |> response(403)
    end

    test "an anonymous reader is refused", %{conn: conn} do
      assert conn |> get(~p"/admin/export/site.zip") |> response(403)
    end
  end

  describe "the download" do
    test "is a ZIP named after the site", %{conn: conn} do
      conn =
        conn
        |> signed_in(user_fixture(%{email: "ops@example.com", role: "admin"}))
        |> get(~p"/admin/export/site.zip")

      assert conn.status == 200
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/zip"
      assert conn |> get_resp_header("content-disposition") |> hd() =~ "site_"
    end

    test "says the archive cannot be resumed", %{conn: conn} do
      conn =
        conn
        |> signed_in(user_fixture(%{email: "ops@example.com", role: "admin"}))
        |> put_req_header("range", "bytes=100-")
        |> get(~p"/admin/export/site.zip")

      # The archive is generated while it is sent, so a byte range has nothing
      # to point at. A browser that is told so starts again instead of asking
      # for a part the server would answer with the whole thing.
      assert conn |> get_resp_header("accept-ranges") == ["none"]
      assert conn.status == 200
      refute List.keyfind(conn.resp_headers, "content-range", 0)
    end

    test "a prepared archive says how big it is, and resumes where it stopped", %{conn: conn} do
      bytes = prepare_archive()
      ops = user_fixture(%{email: "ops@example.com", role: "admin"})

      head = conn |> signed_in(ops) |> get(~p"/admin/export/site.zip")
      assert head.status == 200
      assert head |> get_resp_header("accept-ranges") == ["bytes"]

      # The length is the adapter's to write when it sends a file (Bandit sets
      # `content-length` from it); what this test can hold on to is that the
      # whole file went out, byte for byte.
      assert byte_size(head.resp_body) == bytes

      # What a browser sends when it lost the connection: the rest, and nothing
      # before it. A 206 with the tail is the whole of what "resume" means.
      resumed =
        conn
        |> signed_in(ops)
        |> put_req_header("range", "bytes=100-")
        |> get(~p"/admin/export/site.zip")

      assert resumed.status == 206
      assert resumed |> get_resp_header("content-range") == ["bytes 100-#{bytes - 1}/#{bytes}"]
      assert byte_size(resumed.resp_body) == bytes - 100
      assert resumed.resp_body == binary_part(head.resp_body, 100, bytes - 100)
    end

    test "a resume past the end is refused rather than answered with nothing", %{conn: conn} do
      bytes = prepare_archive()

      conn =
        conn
        |> signed_in(user_fixture(%{email: "ops@example.com", role: "admin"}))
        |> put_req_header("range", "bytes=#{bytes + 1}-")
        |> get(~p"/admin/export/site.zip")

      assert conn.status == 416
      assert conn |> get_resp_header("content-range") == ["bytes */#{bytes}"]
    end
  end

  # Builds the real archive through the registry a download reads, and waits for
  # the file. The demo snapshot is small; the point is the shape, not the size.
  defp prepare_archive do
    assert :started =
             Artifact.prepare(Export.site_artifact(),
               by: "ops@example.com",
               build: fn emit ->
                 %Scope{admin?: true}
                 |> Export.site_archive()
                 |> ConfluencePhxMirror.Export.Zip.chunks()
                 |> Enum.each(fn chunk -> emit.(IO.iodata_to_binary(chunk)) end)
               end
             )

    Enum.reduce_while(1..200, 0, fn _attempt, waited ->
      case Artifact.status(Export.site_artifact()) do
        {:ready, %{bytes: bytes}} ->
          {:halt, bytes}

        _not_yet ->
          Process.sleep(25)
          if waited > 5_000, do: raise("the archive was never prepared")
          {:cont, waited + 25}
      end
    end)
  end

  defp signed_in(conn, user), do: init_test_session(conn, %{"user_id" => user.id})
end
