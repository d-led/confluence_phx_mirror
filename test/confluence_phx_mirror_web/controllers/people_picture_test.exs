defmodule ConfluencePhxMirrorWeb.PeoplePictureTest do
  @moduledoc """
  A person's face comes from the site, and the mirror serves it.

  The row behind it is a directory entry, not an account: it is written by a
  sync, so a person who never signs in here still has one. Both halves are
  checked — the page draws the picture when there is one and the initials when
  there is not, and the picture's own address answers with the bytes the site
  published.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Sync

  # The demo's open page is written by Jane Doe, and this is the account its
  # byline carries.
  @author "557058:jane.doe"

  # Enough of a PNG to be bytes and not text.
  @picture <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82>>

  setup do
    demo_snapshot!()
    :ok
  end

  test "a people run records the person the byline names" do
    assert {:ok, _run} = Sync.run(:people, gate: ConfluencePhxMirror.UnclaimedGate)

    assert Mirror.find_person(@author).display_name == "Jane Doe"
  end

  test "the page draws the picture the site published, and the mirror serves it", %{conn: conn} do
    store_person(@author)

    html = conn |> get(URLs.person_path(@author)) |> html_response(200)

    assert html =~ ~s(src="#{URLs.person_path(@author)}/avatar")

    answer = conn |> get(URLs.person_path(@author) <> "/avatar")

    assert response(answer, 200) == @picture
    assert get_resp_header(answer, "content-type") == ["image/png"]
  end

  test "a person with no picture keeps the initials", %{conn: conn} do
    html = conn |> get(URLs.person_path(@author)) |> html_response(200)

    refute html =~ "/avatar"

    refused = conn |> get(URLs.person_path(@author) <> "/avatar")
    assert response(refused, 404) =~ "no picture of that person"
  end

  defp store_person(account_id) do
    key = Key.person_avatar(account_id, "image/png")
    {:ok, _key} = Store.put(key, @picture)

    {:ok, _person} =
      Mirror.upsert_person(%{
        account_id: account_id,
        display_name: "Jane Doe",
        avatar_blob_key: key,
        avatar_media_type: "image/png",
        avatar_sha256: :crypto.hash(:sha256, @picture) |> Base.encode16(case: :lower),
        synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
  end
end
