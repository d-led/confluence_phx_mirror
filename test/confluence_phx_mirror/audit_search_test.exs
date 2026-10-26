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
    jane = Accounts.get_user_by_email("jane@example.com")

    # A group whose name carries a percent sign: the reader typed a percent, so a
    # percent is what the log must look for.
    {:ok, _} = Accounts.update_groups(jane, ["100%"], {:user, jane})

    matching = Audit.search(query: "%")

    assert Enum.any?(matching, &(&1.metadata["to"] == "100%")),
           "a percent finds the event that carries one"

    assert length(matching) < length(Audit.search()),
           "and does not find everything, the way a wildcard would"
  end

  test "every word has to match, and each may match a different part of the event" do
    # "member" is what the role was and "admin" is what it became: an operator
    # who saw both in the log asks for both.
    assert Audit.search(query: "member admin") |> Enum.map(& &1.action) ==
             ["user.role_changed"]

    # The account was created as a member and never was an admin.
    assert Audit.search(query: "jane@example.com created admin") == []
  end

  test "one word nobody's event carries empties the log" do
    assert Audit.search(query: "jane@example.com nonsense") == []
  end

  test "a box holding only spaces asks for nothing" do
    assert length(Audit.search(query: "   ")) == length(Audit.search([]))
  end
end
