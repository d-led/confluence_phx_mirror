defmodule ConfluencePhxMirror.Sync.PersonalSpacesTest do
  @moduledoc """
  Everyone has a personal space; mirroring it is a decision, not an accident.
  """
  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Confluence.PersonalSpaceSource
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :sync)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :sync, previous) end)
    :ok
  end

  test "a snapshot leaves the personal space out" do
    {:ok, run} = Sync.run(:snapshot, source: PersonalSpaceSource)

    refute Mirror.get_space_by_key(PersonalSpaceSource.personal_key())
    assert run.stats["skipped_spaces"] == 1
    assert Mirror.get_space_by_key("ENG")
  end

  test "a deployment can ask for personal spaces" do
    put_sync(personal_spaces: true)

    {:ok, run} = Sync.run(:snapshot, source: PersonalSpaceSource)

    assert Mirror.get_space_by_key(PersonalSpaceSource.personal_key())
    assert run.stats["skipped_spaces"] == 0
  end

  test "an incremental run does not take a personal space in through the back door" do
    {:ok, run} =
      Sync.run(:incremental,
        source: PersonalSpaceSource,
        since: ~U[2000-01-01 00:00:00Z]
      )

    refute Mirror.get_space_by_key(PersonalSpaceSource.personal_key())
    assert run.stats["skipped_personal"] == 1
    assert Mirror.get_space_by_key("ENG")
  end

  defp put_sync(opts) do
    Application.put_env(:confluence_phx_mirror, :sync, Keyword.merge(existing(), opts))
  end

  defp existing, do: Application.get_env(:confluence_phx_mirror, :sync, [])
end
