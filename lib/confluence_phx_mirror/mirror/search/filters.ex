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
      |> spaces(params)
      |> values("label", params["labels"] || params["label"])
      |> types(params["types"] || params["type"])
      |> equality("creator", params["creator"])
      |> number("ancestor", params["ancestor"])
      |> modified(params)

    case clauses do
      [] -> :empty
      _ -> {:ok, Enum.join(clauses, " AND "), terms(params["q"])}
    end
  end

  @doc """
  The reader's words as one query: the four text boxes of advanced search say
  *all of these*, *this phrase*, *any of these* and *none of these*, which is
  exactly the query language the text engine reads.

      iex> compose_text(%{"q" => "rate limit", "phrase" => "token bucket", "none" => "draft"})
      "rate limit \\"token bucket\\" -draft"
  """
  @spec compose_text(params()) :: String.t()
  def compose_text(params) do
    params = if is_map(params), do: normalise(params), else: %{}

    [
      words(params["q"]),
      phrase(params["phrase"]),
      any_of(params["any"]),
      none_of(params["none"])
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
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
  def field_keys,
    do:
      ~w(space spaces labels label types type creator ancestor updated updated_after from to title)

  defp words(value), do: value |> to_string() |> String.replace("\"", " ") |> squash()

  defp phrase(value) do
    case squash(to_string(value)) do
      "" -> ""
      words -> ~s("#{words}")
    end
  end

  defp any_of(value) do
    case value |> to_string() |> tokenise() do
      [] -> ""
      words -> "(" <> Enum.join(words, " OR ") <> ")"
    end
  end

  defp none_of(value) do
    value
    |> to_string()
    |> tokenise()
    |> Enum.map_join(" ", &("-" <> &1))
  end

  # A phrase or a list of alternatives may contain its own punctuation; only
  # the words matter here.
  defp tokenise(value) do
    value
    |> String.replace(~r/["()]/, " ")
    |> squash()
    |> String.split(" ", trim: true)
  end

  defp squash(value), do: value |> String.split(~r/\s+/u, trim: true) |> Enum.join(" ")

  defp trim(nil), do: nil
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value) when is_list(value), do: value |> Enum.join(",") |> String.trim()
  defp trim(value), do: value |> to_string() |> String.trim()

  defp text(clauses, value) when value in [nil, ""], do: clauses
  defp text(clauses, value), do: clauses ++ [~s(text ~ #{cql_string(value)})]

  defp equality(clauses, _field, value) when value in [nil, ""], do: clauses

  defp equality(clauses, field, value), do: clauses ++ [~s(#{field} = #{cql_string(value)})]

  # Choosing several spaces widens the search ("any of these"), unlike labels,
  # which narrow it.
  defp spaces(clauses, params) do
    keys = params |> Map.get("spaces", "") |> split()

    case keys do
      [] -> equality(clauses, "space", params["space"])
      [key] -> equality(clauses, "space", key)
      keys -> clauses ++ ["(" <> Enum.map_join(keys, " OR ", &"space = #{cql_string(&1)}") <> ")"]
    end
  end

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

  # "7d", "30d", "90d", "365d", "any", an ISO date, or an explicit range.
  defp modified(clauses, params) do
    clauses
    |> modified_after(params["updated"] || params["updated_after"])
    |> modified_between(params)
  end

  defp modified_after(clauses, value) when value in [nil, "", "any"], do: clauses

  defp modified_after(clauses, value) do
    case cutoff(value) do
      nil -> clauses
      date -> clauses ++ [~s(lastmodified > "#{date}")]
    end
  end

  defp modified_between(clauses, params) do
    clauses
    |> changed_after(params["from"])
    |> changed_before(params["to"])
  end

  defp changed_after(clauses, value) when value in [nil, ""], do: clauses

  defp changed_after(clauses, value) do
    case iso(value) do
      nil -> clauses
      date -> clauses ++ [~s(lastmodified > "#{date}")]
    end
  end

  defp changed_before(clauses, value) when value in [nil, ""], do: clauses

  defp changed_before(clauses, value) do
    case iso(value) do
      nil -> clauses
      date -> clauses ++ [~s(lastmodified < "#{date}")]
    end
  end

  defp iso(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(date)
      _ -> nil
    end
  end

  defp cutoff("today"), do: days_ago(0)
  defp cutoff("yesterday"), do: days_ago(1)

  defp cutoff(value) do
    case Regex.run(~r/^(\d{1,3})d$/, value) do
      [_, days] -> days_ago(String.to_integer(days))
      nil -> iso(value)
    end
  end

  defp days_ago(days), do: Date.utc_today() |> Date.add(-days) |> Date.to_iso8601()

  # The tokenizer has no escape syntax; dropping quote characters is enough for
  # user input and keeps the generated CQL unambiguous.
  defp cql_string(value) do
    cleaned = String.replace(value, ~r/["'\\]/, " ")
    ~s("#{cleaned}")
  end
end
