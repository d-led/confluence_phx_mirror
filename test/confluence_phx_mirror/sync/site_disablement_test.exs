defmodule ConfluencePhxMirror.Sync.SiteDisablementTest do
  @moduledoc """
  Confluence saying an account is no longer active is a fact the mirror has to
  carry over: the person must stop reading here even if nobody here touched
  their account, and the transition belongs in the audit log.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Sync

  # The demo snapshot marks this author's Atlassian account as inactive.
  @inactive_account "557058:sam.rivera"

  setup do
    demo_snapshot!()
    :ok
  end

  test "a mirror account the site switched off is marked, and the mark is audited" do
    user = account_for(@inactive_account, "sam@example.com")

    assert {:ok, run} = Sync.run(:snapshot)
    assert run.status == "succeeded"

    assert User.disabled_on_site?(Accounts.get_user(user.id))
    refute User.disabled_here?(Accounts.get_user(user.id))
    assert audited_once?("user.site_disabled", user.id)
  end

  test "a sync that finds nothing new does not repeat the audit entry" do
    user = account_for(@inactive_account, "sam@example.com")

    {:ok, _} = Sync.run(:snapshot)
    {:ok, _} = Sync.run(:snapshot)

    assert audited_once?("user.site_disabled", user.id)
  end

  test "an account the site still lists as active keeps its access" do
    user = account_for("557058:jane.doe", "jane@example.com")

    {:ok, _} = Sync.run(:snapshot)

    refute User.disabled?(Accounts.get_user(user.id))
  end

  test "an account the site no longer has is marked gone, not merely switched off" do
    user = account_for("557058:gone", "gone@example.com")

    assert {:ok, _run} =
             Sync.run(:snapshot, source: ConfluencePhxMirror.Confluence.AccountGoneSource)

    reloaded = Accounts.get_user(user.id)
    assert User.deleted_on_site?(reloaded)
    refute User.disabled_on_site?(reloaded)
    assert audited_once?("user.site_deleted", user.id)
  end

  defp account_for(account_id, email) do
    user = user_fixture(%{email: email})

    {:ok, user} =
      user
      |> User.identity_changeset(%{confluence_account_id: account_id})
      |> ConfluencePhxMirror.Repo.update()

    user
  end

  defp audited_once?(action, user_id) do
    Repo.aggregate(
      from(e in Event, where: e.action == ^action and e.entity_id == ^to_string(user_id)),
      :count
    ) == 1
  end
end
