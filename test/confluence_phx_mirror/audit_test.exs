defmodule ConfluencePhxMirror.AuditTest do
  use ConfluencePhxMirror.DataCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SyncRun

  describe "logging a domain entry" do
    test "records the entity the entry describes" do
      user = %User{id: 7, email: "jane@acme.com", groups: ["ops"]}

      event = Audit.log(Audit.system_actor(), User.audit_event_groups_changed(user, ["member"]))

      assert event.action == "user.groups_changed"
      assert event.entity_type == "user"
      assert event.entity_id == "7"
      assert event.actor_type == "system"
      assert event.metadata["email"] == "jane@acme.com"
      assert event.metadata["from"] == "member"
      assert event.metadata["to"] == "ops"
    end

    test "keeps the actor that made the change" do
      user = user_fixture(%{email: "ops@example.com"})

      event = Audit.log({:user, user}, User.audit_event_role_changed(user, "member"))

      assert event.actor_type == "user"
      assert event.actor_label == "ops@example.com"
      assert event.action == "user.role_changed"
    end

    test "stores metadata as JSON Postgres can query" do
      run = %SyncRun{id: 42}

      event = Audit.log(Audit.system_actor(), SyncRun.audit_event_started(run, :snapshot, "demo"))

      assert %{"mode" => "snapshot", "source" => "demo"} == Repo.get!(Event, event.id).metadata
    end

    test "a finished run keeps its counters as nested metadata" do
      run = %SyncRun{
        id: 43,
        mode: "snapshot",
        status: "succeeded",
        stats: %{
          "pages" => 43,
          "changed" => 40,
          "unchanged" => 3,
          "attachments" => 15,
          "errors" => []
        }
      }

      event = Audit.log(Audit.system_actor(), SyncRun.audit_event_finished(run))
      metadata = Repo.get!(Event, event.id).metadata

      assert metadata["stats"] == %{
               "pages" => 43,
               "changed" => 40,
               "unchanged" => 3,
               "attachments" => 15,
               "errors" => []
             }

      # The readable summary beside the counters: what a reader asks the log for
      # after "which sync was that?" — listed, changed, skipped.
      assert metadata["indexed"]["listed"] == 43
      assert metadata["indexed"]["unchanged"] == 3
      assert metadata["mode"] == "snapshot"
      assert metadata["status"] == "succeeded"

      # Counters stay nested; flattening them would put `pages` and `errors` in
      # the same map as `mode` and `trigger`.
      refute Map.has_key?(metadata, "pages")
    end

    test "lists events newest first" do
      user = user_fixture(%{email: "recent@example.com"})
      Audit.log({:user, user}, User.audit_event_signed_in(user))
      Audit.log({:user, user}, User.audit_event_signed_out(user))

      assert [%{action: "user.signed_out"}, %{action: "user.signed_in"} | _] = Audit.recent(2)
    end
  end
end
