defmodule ConfluencePhxMirrorWeb.Time do
  @moduledoc "Human-friendly timestamps used across the mirror UI."

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
  def date(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%-d %b %Y")

  @doc "Date and time in UTC."
  def datetime(nil), do: "unknown"
  def datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%-d %b %Y, %H:%M UTC")

  @doc "ISO date for `datetime` attributes."
  def iso(nil), do: nil
  def iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

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
end
