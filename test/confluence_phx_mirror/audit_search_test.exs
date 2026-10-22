defmodule ConfluencePhxMirror.AuditSearchTest do
  @moduledoc """
  The audit log is queried the way an operator asks: by what happened, to whom,
  and by whose hand.
  """
  use ConfluencePhxMirror.DataCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Audit

  setup do
    jane = user_fixture(%{email: "jane@example.com"})
    ops = user_fixture(%{email: "ops@example.com", role: "admin"})

    {:ok, _} = Accounts.change_role(jane, "admin", {:user, ops})
    :ok
  end

  test "an event says which account changed, from what to what, and by whom" do
    event = Audit.search(query: "jane@example.com") |> List.first()

    assert event.action == "user.role_changed"
    assert event.actor_label == "ops@example.com"
    assert event.metadata["email"] == "jane@example.com"
    assert event.metadata["from"] == "member"
    assert event.metadata["to"] == "admin"
  end

  test "events are newest first" do
    {:ok, _} =
      Accounts.update_groups(
        Accounts.get_user_by_email("jane@example.com"),
        ["a"],
        {:system, "test"}
      )

    actions = Audit.search(query: "jane@example.com") |> Enum.map(& &1.action)

    assert actions == ["user.groups_changed", "user.role_changed", "user.created"]
  end

  test "a query matches the actor as well as the subject" do
    events = Audit.search(query: "ops@example.com")

    assert Enum.any?(events, &(&1.actor_label == "ops@example.com"))
    assert Enum.any?(events, &(&1.action == "user.role_changed"))
  end

  test "an action filter narrows the log" do
    assert Audit.search(action: "user.created") |> Enum.all?(&(&1.action == "user.created"))
    assert Audit.search(action: "user.role_changed") |> length() == 1
  end

  test "an actor filter separates people from the system" do
    system_events = Audit.search(actor_type: "system")
    assert Enum.any?(system_events, &(&1.action == "user.created"))

    assert Audit.search(actor_type: "user") |> Enum.map(& &1.action) == ["user.role_changed"]
  end

  test "a query with SQL wildcards is treated literally" do
    assert Audit.search(query: "%") == []
  end
end
