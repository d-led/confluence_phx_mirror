defmodule ConfluencePhxMirror.Audit do
  @moduledoc """
  Append-only audit trail.

  Every state change in the mirror is recorded with an actor: a signed-in user,
  the system (scheduled syncs), or a webhook delivery. If writing an audit event
  fails, the operation itself fails — an unauditable change must not happen.
  """

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Repo

  @type actor ::
          {:user, ConfluencePhxMirror.Accounts.User.t()}
          | {:system, String.t()}
          | {:webhook, integer() | nil}

  @doc "Records an audit event. Raises if it cannot be persisted."
  @spec record(actor(), String.t(), String.t() | nil, String.t() | integer() | nil, map()) ::
          Event.t()
  def record(actor, action, entity_type, entity_id, metadata \\ %{}) do
    {actor_type, actor_id, actor_label} = normalise_actor(actor)

    %Event{}
    |> Event.changeset(%{
      actor_type: actor_type,
      actor_id: actor_id,
      actor_label: actor_label,
      action: action,
      entity_type: entity_type,
      entity_id: to_string(entity_id),
      metadata: stringify(metadata),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  def system(action, entity_type, entity_id, metadata \\ %{}) do
    record({:system, "sync"}, action, entity_type, entity_id, metadata)
  end

  def webhook(action, delivery_id, metadata \\ %{}) do
    record({:webhook, delivery_id}, action, "webhook_delivery", delivery_id, metadata)
  end

  def user(
        %ConfluencePhxMirror.Accounts.User{} = user,
        action,
        entity_type,
        entity_id,
        metadata \\ %{}
      ) do
    record({:user, user}, action, entity_type, entity_id, metadata)
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
