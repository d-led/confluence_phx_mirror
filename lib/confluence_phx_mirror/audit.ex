defmodule ConfluencePhxMirror.Audit do
  @moduledoc """
  Append-only audit trail.

  This module is the only writer. The shape of an event belongs to the domain
  that owns it — `Mirror.Page.audit_event_updated/2`,
  `Sync.SyncRun.audit_event_failed/2`, `Webhooks.Delivery.audit_event_queued/4`
  — so a call site only says who acted:

      Audit.log(actor, Page.audit_event_updated(page, space))

  If writing an event fails, the operation fails too: an unauditable change
  must not happen.
  """

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Audit.{Entry, Event}
  alias ConfluencePhxMirror.Repo

  @type actor :: {:user, User.t()} | {:system, String.t()} | {:webhook, integer() | nil}

  @doc "The actor of changes the mirror makes to itself, e.g. a scheduled sync."
  @spec system_actor() :: actor()
  def system_actor, do: {:system, "sync"}

  @doc "Records an audit event. Raises if it cannot be persisted."
  @spec log(actor(), Entry.t()) :: Event.t()
  def log(actor, %Entry{} = entry) do
    {actor_type, actor_id, actor_label} = normalise_actor(actor)

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
  end

  @doc "Newest first, for the admin audit view."
  def recent(limit \\ 100) do
    import Ecto.Query

    Repo.all(
      from e in Event,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end

  defp normalise_actor({:user, %{id: id, email: email}}), do: {"user", to_string(id), email}
  defp normalise_actor({:system, name}), do: {"system", nil, name}
  defp normalise_actor({:webhook, id}), do: {"webhook", to_string(id), "webhook"}

  defp stringify(metadata) do
    Map.new(metadata, fn {key, value} -> {to_string(key), encode(value)} end)
  end

  defp encode(nil), do: nil
  defp encode(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp encode(value)
       when is_atom(value) or is_number(value) or is_binary(value) or is_boolean(value),
       do: value

  defp encode(value), do: inspect(value)
end
