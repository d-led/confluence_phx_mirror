defmodule ConfluencePhxMirror.Mirror.Search.CQL.Functions do
  @moduledoc """
  The date functions CQL allows in a clause, resolved when the query is parsed.

  `now()`, `startOfDay()` and `endOfDay()` — each with the week, month and year
  version — evaluate to one absolute instant, so the rest of the mirror sees a
  timestamp and nothing downstream has to ask what "today" meant when a query
  was written.

  Every one takes an optional increment, `(+/-)nn(y|M|w|d|h|m)`, the sign
  optional and defaulting to plus (`y` a year, `M` a month, `w` weeks, `d` days,
  `h` hours, `m` minutes): `startOfDay("-7d")` is the start of the day a week
  ago, `endOfMonth()` the last second of this month.

  The user-specific functions are refused, not faked. A mirror answers a query
  once, for everybody, so "the reader" is not something it can ask about —
  `currentUser()`, `favouriteSpaces()`, `recentlyViewedContent()` and
  `recentlyViewedSpaces()` name a person this mirror has no opinion about.
  """

  @type instant :: {:ok, DateTime.t()}
  @type error :: {:error, String.t()}

  @boundaries %{
    "startofday" => {:start, "day"},
    "endofday" => {:end, "day"},
    "startofweek" => {:start, "week"},
    "endofweek" => {:end, "week"},
    "startofmonth" => {:start, "month"},
    "endofmonth" => {:end, "month"},
    "startofyear" => {:start, "year"},
    "endofyear" => {:end, "year"}
  }

  @increment ~r/^([+-]?)(\d+)([yMwdhm])$/

  @doc "The function names the mirror can resolve, lowercased."
  @spec names() :: [String.t()]
  def names, do: ["now" | Map.keys(@boundaries)]

  @doc "Function names that exist in CQL but depend on who is asking."
  @spec user_specific() :: [String.t()]
  def user_specific,
    do: ~w(currentuser favouritespaces recentlyviewedcontent recentlyviewedspaces)

  @doc "Whether `name` (any case) is one of `user_specific/0`."
  @spec user_specific?(String.t()) :: boolean()
  def user_specific?(name), do: String.downcase(name) in user_specific()

  @doc "Whether `name` (any case) is one of `names/0`."
  @spec known?(String.t()) :: boolean()
  def known?(name), do: String.downcase(name) in names()

  @doc """
  Resolves `name(arguments)` to an instant, relative to `now`.

      iex> resolve("startofday", ["-7d"], ~U[2026-10-28 15:04:05Z])
      {:ok, ~U[2026-10-21 00:00:00Z]}

      iex> resolve("endofmonth", [], ~U[2026-02-10 15:04:05Z])
      {:ok, ~U[2026-02-28 23:59:59Z]}
  """
  @spec resolve(String.t(), [String.t()], DateTime.t()) :: instant() | error()
  def resolve(name, arguments, now \\ DateTime.utc_now()) do
    with {:ok, increment} <- increment(arguments) do
      shifted = shift(now, increment)

      case Map.get(@boundaries, String.downcase(name)) do
        nil -> {:ok, shifted}
        {edge, unit} -> {:ok, boundary(edge, unit, shifted)}
      end
    end
  end

  defp increment([]), do: {:ok, {:plus, 0, "d"}}

  defp increment([argument]) do
    case Regex.run(@increment, String.trim(argument)) do
      [_, sign, number, unit] ->
        {:ok, {if(sign == "-", do: :minus, else: :plus), String.to_integer(number), unit}}

      nil ->
        {:error, "expected an increment like \"-7d\", got #{inspect(argument)}"}
    end
  end

  defp increment(_arguments), do: {:error, "takes at most one increment, like \"-7d\""}

  defp shift(now, {:plus, 0, _unit}), do: now
  defp shift(now, {sign, number, unit}), do: move(now, sign, number, unit)

  defp move(now, :plus, number, "y"), do: %{now | year: now.year + number}
  defp move(now, :minus, number, "y"), do: %{now | year: now.year - number}

  defp move(now, sign, number, "M") do
    months = now.year * 12 + (now.month - 1) + signed(sign, number)
    date = Date.new!(div(months, 12), rem(months, 12) + 1, 1)
    day = min(now.day, Date.days_in_month(date))
    %{now | year: date.year, month: date.month, day: day}
  end

  defp move(now, sign, number, "w"), do: DateTime.add(now, signed(sign, number) * 7 * 86_400)
  defp move(now, sign, number, "d"), do: DateTime.add(now, signed(sign, number) * 86_400)
  defp move(now, sign, number, "h"), do: DateTime.add(now, signed(sign, number) * 3600)
  defp move(now, sign, number, "m"), do: DateTime.add(now, signed(sign, number) * 60)

  defp signed(:plus, number), do: number
  defp signed(:minus, number), do: -number

  defp boundary(edge, "day", now), do: on(edge, DateTime.to_date(now), now)

  defp boundary(:start, "week", now) do
    monday = now |> DateTime.to_date() |> Date.beginning_of_week(:monday)
    on(:start, monday, now)
  end

  defp boundary(:end, "week", now) do
    sunday = now |> DateTime.to_date() |> Date.beginning_of_week(:monday) |> Date.add(6)
    on(:end, sunday, now)
  end

  defp boundary(edge, "month", now) do
    date = DateTime.to_date(now)

    case edge do
      :start -> on(:start, Date.beginning_of_month(date), now)
      :end -> on(:end, Date.end_of_month(date), now)
    end
  end

  defp boundary(:start, "year", now), do: on(:start, Date.new!(now.year, 1, 1), now)
  defp boundary(:end, "year", now), do: on(:end, Date.new!(now.year, 12, 31), now)

  # A range reads inclusively, so "the end of the day" is its last second rather
  # than the first of the next one: `lastmodified <= endOfDay()` then includes
  # everything written today, which is what the author of the query meant.
  defp on(edge, date, _now), do: DateTime.new!(date, time(edge), "Etc/UTC")

  defp time(:start), do: ~T[00:00:00]
  defp time(:end), do: ~T[23:59:59]
end
