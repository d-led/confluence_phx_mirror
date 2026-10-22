defmodule ConfluencePhxMirror.Audit do
  @moduledoc """
  Append-only audit log.

  What belongs here is a *decision or a change a person cares about*: an account
  created or promoted, a token issued, a subscription made, a sync that ran and
  what it did. Copying every page and every attachment into the log would bury
  those under sync noise — that detail belongs in the console log, which is
  where `sync.ex` writes it.

  This module is the only writer. The shape of an event belongs to the domain
  that owns it (`Accounts.User.audit_event_role_changed/2`,
  `Sync.SyncRun.audit_event_finished/1`,
  `Webhooks.Delivery.audit_event_queued/4`), so a call site only says who acted:

      Audit.log(actor, User.audit_event_role_changed(user, previous))

  If writing an event fails, the operation fails too: an unauditable change
  must not happen.
  """

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Audit.{Entry, Event}
  alias ConfluencePhxMirror.Repo

  @topic "audit"

  @type actor :: {:user, User.t()} | {:system, String.t()} | {:webhook, integer() | nil}

  @doc "The actor of changes the mirror makes to itself, e.g. a scheduled sync."
  @spec system_actor() :: actor()
  def system_actor, do: {:system, "sync"}

  @doc "Records an audit event. Raises if it cannot be persisted."
  @spec log(actor(), Entry.t()) :: Event.t()
  def log(actor, %Entry{} = entry) do
    {actor_type, actor_id, actor_label} = normalise_actor(actor)

    event =
      %Event{}
      |> Event.changeset(%{
        actor_type: actor_type,
        actor_id: actor_id,
        actor_label: actor_label,
        action: entry.action,
        entity_type: entry.entity_type,
        entity_id: to_string(entry.entity_id),
        metadata: stringify(entry.metadata),
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    Phoenix.PubSub.broadcast(
      ConfluencePhxMirror.PubSub,
      @topic,
      {:audit_event, event}
    )

    event
  end

  @doc "Topic every new audit event is broadcast on."
  def topic, do: @topic

  @doc "Newest first, for the admin audit view."
  def recent(limit \\ 100) do
    import Ecto.Query

    Repo.all(
      from e in Event,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end

  @doc """
  One page of the audit log, newest first.

  `:query` is matched against the action, the actor and the entity id (so
  `jane@acme.com` finds both what she did and what was done to her account),
  `:action` and `:actor_type` narrow it further.
  """
  def search(opts \\ []) do
    import Ecto.Query

    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    Event
    |> filter_query(Keyword.get(opts, :query))
    |> filter_action(Keyword.get(opts, :action))
    |> filter_actor(Keyword.get(opts, :actor_type))
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  @doc "Distinct actions in the log, for the filter menu."
  def actions do
    import Ecto.Query

    Repo.all(from e in Event, distinct: true, select: e.action, order_by: [asc: e.action])
  end

  @doc """
  The event as a sentence a human can read, instead of a bare event name.

  `%{action: "user.role_changed", metadata: %{"email" => "jane@acme.com",
  "from" => "member", "to" => "admin"}}` reads as
  "Changed jane@acme.com from member to admin".
  """
  def describe(%{action: "user." <> kind} = event), do: user_sentence(kind, event)
  def describe(%{action: "sync." <> kind} = event), do: sync_sentence(kind, event)
  def describe(%{action: "api_token." <> kind} = event), do: token_sentence(kind, event)

  def describe(%{action: "subscription." <> kind, metadata: meta}),
    do: "Subscription #{kind} #{meta["email"] || meta["page"] || ""}" |> String.trim()

  def describe(%{action: "webhook." <> kind, metadata: meta}),
    do: "Webhook #{kind}: #{meta["event"] || meta["event_type"] || "delivery"}"

  def describe(%{action: action}), do: action

  defp user_sentence("created", %{metadata: meta}),
    do: "Created the account #{meta["email"]} as #{meta["role"] || "member"}"

  defp user_sentence("role_changed", %{metadata: meta}),
    do: "Changed #{meta["email"]} from #{meta["from"] || "?"} to #{meta["to"] || meta["role"]}"

  defp user_sentence("groups_changed", %{metadata: meta}) do
    groups = List.wrap(meta["to"] || meta["groups"]) |> Enum.join(", ")
    "Changed the groups of #{meta["email"]} to #{groups}"
  end

  defp user_sentence("login_requested", %{metadata: meta}),
    do: "Sent a sign-in link to #{meta["email"]}"

  defp user_sentence("signed_in", %{metadata: meta}),
    do: "#{meta["email"] || "Someone"} signed in"

  defp user_sentence("signed_out", %{metadata: meta}),
    do: "#{meta["email"] || "Someone"} signed out"

  defp user_sentence(_kind, %{action: action}), do: action

  defp sync_sentence("started", %{metadata: meta}),
    do: "Started a #{meta["mode"]} sync of #{meta["site"] || "the source"}#{trigger(meta)}"

  # A finished run says what it actually did, in the numbers an operator would
  # otherwise have to look up. `stats` is a map on new rows; a row written before
  # the encoder kept nested metadata has none, and falls back to the action name.
  defp sync_sentence("finished", %{metadata: %{"stats" => stats} = meta})
       when is_map(stats),
       do: "Finished a #{meta["mode"]} sync: #{run_summary(stats)}#{trigger(meta)}"

  defp sync_sentence("failed", %{metadata: meta}), do: "A sync failed: #{meta["error"]}"

  defp sync_sentence(_kind, %{action: action}), do: action

  @sync_counters [
    {"spaces", "space"},
    {"pages", "page"},
    {"attachments", "attachment"},
    {"comments", "comment"},
    {"links", "link"},
    {"deleted", "deleted page"},
    {"notifications", "notification"}
  ]

  defp run_summary(stats) do
    counters =
      for {key, noun} <- @sync_counters, amount = stats[key] || 0, amount > 0 do
        "#{amount} #{pluralize(amount, noun)}"
      end

    changes = if counters == [], do: "no changes", else: Enum.join(counters, ", ")

    "#{changes} · #{length(stats["errors"] || [])} errors"
  end

  defp trigger(%{"trigger" => trigger}) when is_binary(trigger) and trigger != "",
    do: ", triggered by #{trigger}"

  defp trigger(_meta), do: ""

  defp pluralize(1, noun), do: noun
  defp pluralize(_amount, "space"), do: "spaces"
  defp pluralize(_amount, noun), do: noun <> "s"

  defp token_sentence("created", %{metadata: meta}),
    do: "Issued the token “#{meta["name"]}” (#{meta["prefix"]}…)"

  defp token_sentence("revoked", %{metadata: meta}), do: "Revoked the token #{meta["prefix"]}…"

  defp token_sentence(_kind, %{action: action}), do: action

  @doc "Who acted: a person's address, the system name, or a webhook."
  def actor(%{actor_type: "system", actor_label: label}), do: "#{label} (system)"
  def actor(%{actor_type: "webhook", actor_id: id}), do: "webhook ##{id}"
  def actor(%{actor_label: label}) when is_binary(label) and label != "", do: label
  def actor(%{actor_type: type}), do: type

  defp filter_query(queryable, query) when is_binary(query) and query != "" do
    import Ecto.Query

    # Wildcards are removed rather than escaped: a reader typing `%` wants to
    # find a literal percent sign, not every row.
    literal = query |> String.replace(["\\", "%", "_"], "") |> String.trim()

    if literal == "" do
      from e in queryable, where: false
    else
      pattern = "%" <> literal <> "%"

      from e in queryable,
        where:
          ilike(e.action, ^pattern) or ilike(e.actor_label, ^pattern) or
            ilike(e.entity_id, ^pattern) or
            fragment("?::text ILIKE ?", e.metadata, ^pattern)
    end
  end

  defp filter_query(queryable, _query), do: queryable

  defp filter_action(queryable, action) when is_binary(action) and action != "" do
    import Ecto.Query
    from e in queryable, where: e.action == ^action
  end

  defp filter_action(queryable, _action), do: queryable

  defp filter_actor(queryable, type) when is_binary(type) and type != "" do
    import Ecto.Query
    from e in queryable, where: e.actor_type == ^type
  end

  defp filter_actor(queryable, _type), do: queryable

  defp normalise_actor({:user, %{id: id, email: email}}), do: {"user", to_string(id), email}
  defp normalise_actor({:system, name}), do: {"system", nil, name}
  defp normalise_actor({:webhook, id}), do: {"webhook", to_string(id), "webhook"}

  defp stringify(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), encode(value)} end)
  end

  defp encode(nil), do: nil
  defp encode(%DateTime{} = value), do: DateTime.to_iso8601(value)

  # Nested metadata (a sync run's counters, a list of groups) stays readable in
  # the row and in the JSON API, so it is encoded rather than printed.
  defp encode(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), encode(value)} end)

  defp encode(list) when is_list(list), do: Enum.map(list, &encode/1)

  defp encode(value)
       when is_atom(value) or is_number(value) or is_binary(value) or is_boolean(value),
       do: value

  defp encode(value), do: inspect(value)
end
