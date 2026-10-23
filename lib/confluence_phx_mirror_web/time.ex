defmodule ConfluencePhxMirrorWeb.Time do
  @moduledoc """
  Human-friendly timestamps used across the mirror UI.

  The mirror keeps every instant in UTC, and so does every function here: a
  `DateTime` that arrives in another zone is shown as the same instant in UTC.
  What the reader sees on their own clock is
  `ConfluencePhxMirrorWeb.TimeComponents.local_time/1`.
  """

  @doc "Relative time such as `3 minutes ago` or `in 2 hours`."
  def ago(nil), do: "never"

  def ago(%DateTime{} = datetime) do
    seconds = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      seconds < 0 -> "in #{magnitude(-seconds)}"
      seconds < 45 -> "just now"
      true -> "#{magnitude(seconds)} ago"
    end
  end

  defp magnitude(seconds) when seconds < 90, do: "a minute"
  defp magnitude(seconds) when seconds < 45 * 60, do: "#{round(seconds / 60)} minutes"
  defp magnitude(seconds) when seconds < 90 * 60, do: "an hour"
  defp magnitude(seconds) when seconds < 22 * 3600, do: "#{round(seconds / 3600)} hours"
  defp magnitude(seconds) when seconds < 36 * 3600, do: "a day"
  defp magnitude(seconds) when seconds < 26 * 86_400, do: "#{round(seconds / 86_400)} days"

  defp magnitude(seconds) when seconds < 320 * 86_400 do
    months(round(seconds / (30 * 86_400)))
  end

  defp magnitude(seconds), do: years(round(seconds / (365 * 86_400)))

  defp months(1), do: "a month"
  defp months(count), do: "#{count} months"

  defp years(1), do: "a year"
  defp years(count), do: "#{count} years"

  @doc "Calendar date, e.g. `21 Oct 2026`."
  def date(nil), do: "unknown"
  def date(%DateTime{} = datetime), do: datetime |> in_utc() |> Calendar.strftime("%-d %b %Y")

  @doc "Date and time in UTC, e.g. `21 Oct 2026, 09:30 UTC`."
  def datetime(nil), do: "unknown"

  def datetime(%DateTime{} = datetime) do
    datetime |> in_utc() |> Calendar.strftime("%-d %b %Y, %H:%M UTC")
  end

  @doc """
  The instant as ISO 8601 in UTC, for `datetime` attributes: seconds, the
  precision the mirror stores.
  """
  def iso(nil), do: nil

  def iso(%DateTime{} = datetime) do
    datetime |> in_utc() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  @doc "Duration between two datetimes in a compact form."
  def duration(nil, _), do: "—"
  def duration(_, nil), do: "—"

  def duration(%DateTime{} = from, %DateTime{} = to) do
    milliseconds = DateTime.diff(to, from, :millisecond)

    cond do
      milliseconds < 1_000 -> "#{milliseconds} ms"
      milliseconds < 60_000 -> "#{Float.round(milliseconds / 1000, 1)} s"
      true -> "#{round(milliseconds / 60_000)} min"
    end
  end

  # A `DateTime` in any other zone is the same instant, so re-read it in UTC
  # rather than printing its own wall clock next to the word "UTC".
  defp in_utc(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = datetime),
    do: datetime

  defp in_utc(%DateTime{} = datetime) do
    DateTime.from_unix!(DateTime.to_unix(datetime, :microsecond), :microsecond)
  end
end
