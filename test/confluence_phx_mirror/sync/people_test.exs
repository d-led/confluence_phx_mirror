defmodule ConfluencePhxMirror.Sync.PeopleTest do
  @moduledoc """
  The half of a run that asks about people rather than content.

  A site that can answer for a person is asked once per identity the content
  named, and what comes back is stored: the name a byline shows, and the face
  served from the mirror's own blob store. The demo snapshot answers with
  neither, so the shape a live site gives back is written down here.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import Ecto.Query

  alias ConfluencePhxMirror.Confluence.PeopleSource
  alias ConfluencePhxMirror.{Mirror, Repo, Sync}

  test "a person the content named gets the name and the face the site answers with" do
    assert {:ok, run} = Sync.run(:snapshot, source: PeopleSource)

    assert run.stats["people"] > 0

    person = stored_person()

    assert person.display_name == "Jane Doe"
    assert person.avatar_media_type == "image/png"
    assert person.avatar_blob_key
    assert person.avatar_sha256
  end

  # A face is one request per person and the answer is kept, so a run that
  # follows a second later reads nobody — which is what keeps a snapshot from
  # spending a request per person on every tick.
  test "a person already answered is not asked again" do
    assert {:ok, _first} = Sync.run(:snapshot, source: PeopleSource)
    assert {:ok, second} = Sync.run(:snapshot, source: PeopleSource)

    assert second.stats["people"] == 0
  end

  defp stored_person do
    account_id =
      Mirror.known_identities()
      |> Enum.map(& &1.account_id)
      |> Enum.reject(&is_nil/1)
      |> hd()

    Repo.one!(from p in Mirror.Person, where: p.account_id == ^account_id)
  end
end
