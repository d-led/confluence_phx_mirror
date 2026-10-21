defmodule ConfluencePhxMirror.AuditTest do
  use ConfluencePhxMirror.DataCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync.SyncRun

  describe "logging a domain entry" do
    test "records the page the entry describes" do
      demo_snapshot!()
      page = Mirror.get_page!(1002)

      event = Audit.log(Audit.system_actor(), Mirror.Page.audit_event_updated(page, page.space))

      assert event.action == "page.updated"
      assert event.entity_type == "page"
      assert event.entity_id == "1002"
      assert event.actor_type == "system"
      assert event.metadata["space"] == "ENG"
      assert event.metadata["title"] == "Architecture Overview"
      assert event.metadata["version"] == page.version_number
    end

    test "keeps the actor that made the change" do
      user = user_fixture(%{email: "ops@example.com"})

      event = Audit.log({:user, user}, User.audit_event_role_changed(user))

      assert event.actor_type == "user"
      assert event.actor_label == "ops@example.com"
      assert event.action == "user.role_changed"
    end

    test "stores metadata as JSON Postgres can query" do
      run = %SyncRun{id: 42}

      event = Audit.log(Audit.system_actor(), SyncRun.audit_event_started(run, :snapshot, "demo"))

      assert %{"mode" => "snapshot", "source" => "demo"} == Repo.get!(Event, event.id).metadata
    end

    test "lists events newest first" do
      user = user_fixture(%{email: "recent@example.com"})
      Audit.log({:user, user}, User.audit_event_signed_in(user))
      Audit.log({:user, user}, User.audit_event_signed_out(user))

      assert [%{action: "user.signed_out"}, %{action: "user.signed_in"} | _] = Audit.recent(2)
    end
  end
end
