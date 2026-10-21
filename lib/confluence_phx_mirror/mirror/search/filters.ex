defmodule ConfluencePhxMirror.Mirror.Search.Filters do
  @moduledoc """
  Turns structured search parameters into the CQL subset the engine understands.

  This is the only place the UI's filters become a query. Raw CQL is not part of
  the reader UI or the v1 API; the parser exists for the Confluence-compatible
  endpoint and for internal composition.
  """

  @type params :: %{optional(String.t()) => String.t() | nil}

  @doc """
  Builds a CQL string and the terms used for highlighting.

  Returns `:empty` when every filter is blank, so callers can show the idle
  state instead of an unscoped search.
  """
  @spec to_cql(params()) :: {:ok, String.t(), [String.t()]} | :empty
  def to_cql(params) do
    params = normalise(params)

    clauses =
      []
      |> text(params["q"])
      |> equality("space", params["space"])
      |> values("label", params["labels"] || params["label"])
      |> types(params["types"] || params["type"])
      |> equality("creator", params["creator"])
      |> number("ancestor", params["ancestor"])
      |> modified_after(params["updated"] || params["updated_after"])

    case clauses do
      [] -> :empty
      _ -> {:ok, Enum.join(clauses, " AND "), terms(params["q"])}
    end
  end

  @doc "Words to highlight in results, stripped of query punctuation."
  def terms(nil), do: []

  def terms(q) do
    q
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.replace(&1, ~r/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/u, ""))
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.take(8)
  end

  @doc "Normalises params to string keys and trimmed string values."
  def normalise(params) do
    Map.new(params, fn {key, value} -> {to_string(key), trim(value)} end)
  end

  @doc "Field filters that participate in structured search."
  def field_keys, do: ~w(space labels label types type creator ancestor updated updated_after)

  defp trim(nil), do: nil
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value) when is_list(value), do: value |> Enum.join(",") |> String.trim()
  defp trim(value), do: value |> to_string() |> String.trim()

  defp text(clauses, value) when value in [nil, ""], do: clauses
  defp text(clauses, value), do: clauses ++ [~s(text ~ #{cql_string(value)})]

  defp equality(clauses, _field, value) when value in [nil, ""], do: clauses

  defp equality(clauses, field, value), do: clauses ++ [~s(#{field} = #{cql_string(value)})]

  # Several values of one field narrow the result set ("all of these labels").
  defp values(clauses, field, value) do
    value
    |> split()
    |> Enum.reduce(clauses, &(&2 ++ [~s(#{field} = #{cql_string(&1)})]))
  end

  defp types(clauses, value) do
    case value
         |> split()
         |> Enum.map(&String.downcase/1)
         |> Enum.filter(&(&1 in ~w(page blogpost))) do
      [] -> clauses
      [type] -> clauses ++ [~s(type = #{type})]
      types -> clauses ++ ["(" <> Enum.map_join(types, " OR ", &"type = #{&1}") <> ")"]
    end
  end

  defp split(nil), do: []

  defp split(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp number(clauses, _field, value) when value in [nil, ""], do: clauses

  defp number(clauses, field, value) do
    case Integer.parse(value) do
      {number, ""} -> clauses ++ ["#{field} = #{number}"]
      _ -> clauses
    end
  end

  # "7d", "30d", "90d", "365d", "any" or an ISO date.
  defp modified_after(clauses, value) when value in [nil, "", "any"], do: clauses

  defp modified_after(clauses, value) do
    case cutoff(value) do
      nil -> clauses
      date -> clauses ++ [~s(lastmodified > "#{date}")]
    end
  end

  defp cutoff(value) do
    case Regex.run(~r/^(\d{1,3})d$/, value) do
      [_, days] ->
        Date.utc_today()
        |> Date.add(-String.to_integer(days))
        |> Date.to_iso8601()

      nil ->
        case Date.from_iso8601(value) do
          {:ok, date} -> Date.to_iso8601(date)
          _ -> nil
        end
    end
  end

  # The tokenizer has no escape syntax; dropping quote characters is enough for
  # user input and keeps the generated CQL unambiguous.
  defp cql_string(value) do
    cleaned = String.replace(value, ~r/["'\\]/, " ")
    ~s("#{cleaned}")
  end
end
