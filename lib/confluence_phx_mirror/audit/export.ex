defmodule ConfluencePhxMirror.Audit.Export do
  @moduledoc """
  The audit log as a file, without holding it in memory.

  Two formats, because the question decides which one is right:

    * **NDJSON** — one JSON object per line, `metadata` left as the object it
      is. Audit events do not share a shape: a page update carries versions, a
      sync carries counters, a refusal carries a reason. A format that needs a
      fixed column set would either drop those or flatten them into strings;
      a line per event keeps each event's own fields.
    * **CSV** — the stable columns as columns, and `metadata` as a JSON string
      in one cell. This is for the spreadsheet someone will inevitably open;
      the varying part is quoted rather than guessed at.

  Either way the rows are read in keyset batches (`id > last`), oldest first,
  so a million-row log exports with a bounded amount of memory and without
  holding a transaction open while the reader's download crawls.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Audit.Event
  alias ConfluencePhxMirror.Repo

  @batch 500

  @columns ~w(id inserted_at action entity_type entity_id actor_type actor_name actor_email
              actor_account_id actor_label metadata)

  @doc "The rows, oldest first, in batches — the caller sends each one and forgets it."
  @spec batches() :: Enumerable.t()
  def batches, do: Stream.unfold(0, &page/1)

  defp page(last_id) do
    events =
      Repo.all(
        from e in Event,
          where: e.id > ^last_id,
          order_by: [asc: e.id],
          limit: @batch
      )

    case events do
      [] -> nil
      batch -> {batch, List.last(batch).id}
    end
  end

  @doc "The header line, for the format asked for (`:csv` only)."
  @spec header(:csv | :ndjson) :: iodata()
  def header(:csv), do: encode_csv_row(@columns) <> "\n"
  def header(:ndjson), do: []

  @doc "One batch, encoded."
  @spec encode(:csv | :ndjson, [Event.t()]) :: iodata()
  def encode(:ndjson, events), do: Enum.map(events, &(encode_json(&1) <> "\n"))

  def encode(:csv, events), do: Enum.map(events, &(encode_csv_row(row(&1)) <> "\n"))

  defp row(event) do
    [
      event.id,
      DateTime.to_iso8601(event.inserted_at),
      event.action,
      event.entity_type,
      event.entity_id,
      event.actor_type,
      event.actor_name,
      event.actor_email,
      event.actor_account_id,
      event.actor_label,
      Jason.encode!(event.metadata || %{})
    ]
  end

  defp encode_json(event) do
    Jason.encode!(Map.new(@columns, fn column -> {column, field(event, column)} end))
  end

  defp field(event, "id"), do: event.id
  defp field(event, "inserted_at"), do: DateTime.to_iso8601(event.inserted_at)
  defp field(event, "action"), do: event.action
  defp field(event, "entity_type"), do: event.entity_type
  defp field(event, "entity_id"), do: event.entity_id
  defp field(event, "actor_type"), do: event.actor_type
  defp field(event, "actor_name"), do: event.actor_name
  defp field(event, "actor_email"), do: event.actor_email
  defp field(event, "actor_account_id"), do: event.actor_account_id
  defp field(event, "actor_label"), do: event.actor_label
  defp field(event, "metadata"), do: event.metadata

  # RFC 4180: a field is quoted when it holds a comma, a quote or a newline, and
  # a quote inside is doubled. Anything else stays as it is, so numbers and
  # timestamps stay readable in a spreadsheet.
  defp encode_csv_row(values) do
    Enum.map_join(values, ",", &csv_field/1)
  end

  defp csv_field(nil), do: ""

  defp csv_field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp csv_field(value), do: to_string(value)
end
