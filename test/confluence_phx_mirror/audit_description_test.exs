defmodule ConfluencePhxMirror.AuditDescriptionTest do
  @moduledoc """
  An audit entry is read by a person: it says what happened, to whom, and from
  what to what — not which event name was written.
  """
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Audit.Event

  test "an account event names the account and the change" do
    assert sentence("user.created", %{"email" => "jane@acme.com", "role" => "admin"}) ==
             "Created the account jane@acme.com as admin"

    assert sentence("user.created", %{"email" => "jane@acme.com"}) ==
             "Created the account jane@acme.com as member"

    assert sentence(
             "user.role_changed",
             %{"email" => "jane@acme.com", "from" => "member", "to" => "admin"}
           ) == "Changed jane@acme.com from member to admin"

    assert sentence("user.groups_changed", %{"email" => "jane@acme.com", "to" => ["ops", "qa"]}) ==
             "Changed the groups of jane@acme.com to ops, qa"

    assert sentence("user.login_requested", %{"email" => "jane@acme.com"}) ==
             "Sent a sign-in link to jane@acme.com"

    assert sentence("user.signed_in", %{"email" => "jane@acme.com"}) ==
             "jane@acme.com signed in"

    assert sentence("user.signed_out", %{}) == "Someone signed out"
  end

  test "an event the log no longer writes is shown by name" do
    assert sentence("page.updated", %{"title" => "Budget"}) == "page.updated"

    assert sentence("attachment.mirrored", %{"filename" => "diagram.svg"}) ==
             "attachment.mirrored"
  end

  test "a sync event reports where it ran, why, and what it did" do
    assert sentence("sync.started", %{
             "mode" => "snapshot",
             "site" => "https://dled.atlassian.net/wiki",
             "trigger" => "the hourly schedule"
           }) ==
             "Started a snapshot sync of https://dled.atlassian.net/wiki, " <>
               "triggered by the hourly schedule"

    assert sentence(
             "sync.finished",
             %{
               "mode" => "snapshot",
               "stats" => %{
                 "spaces" => 1,
                 "pages" => 43,
                 "attachments" => 15,
                 "comments" => 2,
                 "links" => 77,
                 "errors" => []
               }
             }
           ) ==
             "Finished a snapshot sync: 1 space, 43 pages, 15 attachments, " <>
               "2 comments, 77 links · 0 errors"

    assert sentence("sync.finished", %{"mode" => "webhook", "stats" => %{}}) ==
             "Finished a webhook sync: no changes · 0 errors"

    assert sentence("sync.failed", %{"error" => "unauthorized"}) ==
             "A sync failed: unauthorized"
  end

  test "a run that finished records who triggered it" do
    assert sentence("sync.finished", %{
             "mode" => "snapshot",
             "trigger" => "the admin dashboard, by ops@acme.com",
             "stats" => %{"pages" => 2, "errors" => []}
           }) ==
             "Finished a snapshot sync: 2 pages · 0 errors, " <>
               "triggered by the admin dashboard, by ops@acme.com"
  end

  test "credentials, subscriptions and webhooks read in their own words" do
    assert sentence("api_token.created", %{"name" => "ci", "prefix" => "abc123"}) ==
             "Issued the token “ci” (abc123…)"

    assert sentence("api_token.revoked", %{"prefix" => "abc123"}) ==
             "Revoked the token abc123…"

    assert sentence("subscription.created", %{"email" => "jane@acme.com"}) ==
             "Subscription created jane@acme.com"

    assert sentence("webhook.received", %{"event" => "page_updated"}) ==
             "Webhook received: page_updated"

    assert sentence("webhook.received", %{}) == "Webhook received: delivery"
  end

  test "an action with no sentence of its own is shown as it is" do
    assert sentence("space.created", %{}) == "space.created"
  end

  test "the actor is a person's address, the system's name, or a webhook" do
    assert Audit.actor(%Event{actor_type: "user", actor_label: "jane@acme.com"}) ==
             "jane@acme.com"

    assert Audit.actor(%Event{actor_type: "system", actor_label: "sync"}) == "sync (system)"

    assert Audit.actor(%Event{actor_type: "webhook", actor_id: "12"}) == "webhook #12"

    assert Audit.actor(%Event{actor_type: "user", actor_label: nil}) == "user"
  end

  defp sentence(action, metadata) do
    Audit.describe(%Event{action: action, metadata: metadata})
  end
end
