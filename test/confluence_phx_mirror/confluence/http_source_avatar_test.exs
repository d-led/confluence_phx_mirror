defmodule ConfluencePhxMirror.Confluence.HttpSourceAvatarTest do
  @moduledoc """
  A profile picture, and the credential that must not travel with it.

  The site does not serve pictures: `/wiki/aa-avatar/<id>` answers 302, to
  Gravatar or to Atlassian's initials service. Following that redirect is the
  only way to keep the bytes, and it leaves the site — so the token that can read
  the whole site must not go with it.
  """

  # The source reads its configuration from the application environment.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Confluence.HttpSource
  alias ConfluencePhxMirror.TestConfig

  @account "557058:12861f68-8857-4349-927d-e49dfb30bd52"
  @avatar_path "/wiki/aa-avatar/557058:12861f68-8857-4349-927d-e49dfb30bd52"
  @cdn "https://avatar-management--avatars.us-west-2.prod.public.atl-paas.net/initials/DL-4.png"

  setup do
    TestConfig.put(
      HttpSource,
      base_url: "https://acme.atlassian.net",
      email: "mirror@acme.test",
      api_token: "secret-token",
      retries: 1,
      retry_backoff_ms: 0,
      page_size: 50,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    :ok
  end

  test "reads a person's picture as bytes and media type, though the site only redirects" do
    stub_site()

    assert {:ok, %{display_name: "Jane Doe", avatar: %{body: "PNG", media_type: "image/png"}}} =
             HttpSource.person(@account, [])
  end

  test "the picture is fetched without the site's credential" do
    stub_site()

    HttpSource.person(@account, [])

    assert_received {:asked, "acme.atlassian.net", site_headers}
    assert List.keymember?(site_headers, "authorization", 0)

    assert_received {:fetched, _picture_host, picture_headers}
    refute List.keymember?(picture_headers, "authorization", 0)
  end

  defp stub_site do
    test_process = self()
    Req.Test.stub(__MODULE__, fn conn -> answer(conn, test_process) end)
  end

  defp answer(%{request_path: "/wiki/rest/api/user"} = conn, test_process) do
    send(test_process, {:asked, conn.host, conn.req_headers})

    Req.Test.json(conn, %{
      "displayName" => "Jane Doe",
      "profilePicture" => %{"path" => @avatar_path, "isDefault" => false}
    })
  end

  defp answer(%{host: "acme.atlassian.net"} = conn, test_process) do
    send(test_process, {:asked, conn.host, conn.req_headers})

    conn
    |> Plug.Conn.put_resp_header("location", @cdn)
    |> Plug.Conn.resp(302, "")
  end

  defp answer(conn, test_process) do
    send(test_process, {:fetched, conn.host, conn.req_headers})

    conn
    |> Plug.Conn.put_resp_header("content-type", "image/png")
    |> Plug.Conn.resp(200, "PNG")
  end
end
