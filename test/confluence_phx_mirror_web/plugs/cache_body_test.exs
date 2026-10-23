defmodule ConfluencePhxMirrorWeb.Plugs.CacheBodyTest do
  @moduledoc """
  A webhook signature is computed over the exact bytes that arrived, so the raw
  copy has to be the whole body — including the chunks a large body arrives in.

  The test adapter hands a body over in one piece whatever `:read_length` says,
  so the accumulation is exercised the way `Plug.Parsers` makes the second call:
  on a connection that already carries part of the body.
  """

  use ExUnit.Case, async: true

  import Plug.Conn, only: [assign: 3]

  alias ConfluencePhxMirrorWeb.Plugs.CacheBody

  test "the body is kept for the signature check" do
    conn = Plug.Test.conn(:post, "/webhooks/confluence", "0123456789")

    {:ok, "0123456789", conn} = CacheBody.read_body(conn, length: 100)

    assert conn.assigns.raw_body == "0123456789"
  end

  test "a later chunk is added to the raw copy, not written over it" do
    conn =
      :post
      |> Plug.Test.conn("/webhooks/confluence", "second")
      |> assign(:raw_body, "first-")

    {:ok, "second", conn} = CacheBody.read_body(conn, length: 100)

    assert conn.assigns.raw_body == "first-second"
  end
end
