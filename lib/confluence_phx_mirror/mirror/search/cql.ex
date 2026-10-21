defmodule ConfluencePhxMirror.Mirror.Search.CQL do
  @moduledoc """
  A small, strict CQL parser.

  Confluence's CQL is large; the mirror supports the subset that makes sense for
  a read-only cache:

      space = ENG AND label = architecture
      text ~ "rate limit" OR title ~ "release"
      ancestor = 1000 AND lastmodified > "2026-10-01"
      type = blogpost ORDER BY lastmodified DESC LIMIT 10

  Supported fields: `text`, `title`, `space`, `label`, `type`, `status`,
  `creator`, `ancestor`, `parent`, `id`, `version`, `created`, `lastmodified`.

  The parser returns an AST; `ConfluencePhxMirror.Mirror.Search` compiles it to
  parameterised Ecto queries.
  """

  defmodule Query do
    @moduledoc "Parsed CQL query."
    @enforce_keys [:filter]
    defstruct filter: nil, order_by: nil, limit: nil

    @type t :: %__MODULE__{
            filter: term(),
            order_by: {atom(), :asc | :desc} | nil,
            limit: pos_integer() | nil
          }
  end

  @text_fields [:text, :title]
  @date_fields [:created, :lastmodified]
  @order_atoms %{
    "lastmodified" => :lastmodified,
    "created" => :created,
    "title" => :title,
    "id" => :id,
    "version" => :version
  }

  @fields %{
    "text" => :text,
    "title" => :title,
    "space" => :space,
    "label" => :label,
    "type" => :type,
    "status" => :status,
    "creator" => :creator,
    "ancestor" => :ancestor,
    "parent" => :parent,
    "id" => :id,
    "version" => :version,
    "created" => :created,
    "lastmodified" => :lastmodified
  }

  @doc """
  Parses a CQL string.

      iex> CQL.parse("space = ENG AND label = architecture")
      {:ok, %CQL.Query{filter: {:and, {:cmp, :space, :eq, "ENG"}, {:cmp, :label, :eq, "architecture"}}, order_by: nil, limit: nil}}

  """
  def parse(cql) when is_binary(cql) do
    with {:ok, tokens} <- tokenize(cql),
         {:ok, filter, rest} <- parse_or(tokens),
         {:ok, order_by, limit} <- parse_suffix(rest) do
      {:ok, %Query{filter: filter, order_by: order_by, limit: limit}}
    end
  end

  # ---------------------------------------------------------------------------
  # Tokenizer
  # ---------------------------------------------------------------------------

  defp tokenize(cql), do: tokenize(cql, [])

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<char::utf8, rest::binary>>, acc) when char in [?\s, ?\t, ?\n, ?\r],
    do: tokenize(rest, acc)

  defp tokenize(<<?(, rest::binary>>, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(<<?), rest::binary>>, acc), do: tokenize(rest, [:rparen | acc])
  defp tokenize(<<?,, rest::binary>>, acc), do: tokenize(rest, [:comma | acc])

  defp tokenize(<<?~, rest::binary>>, acc), do: tokenize(rest, [{:op, :contains} | acc])

  defp tokenize(<<?!, ?=, rest::binary>>, acc), do: tokenize(rest, [{:op, :neq} | acc])
  defp tokenize(<<?>, ?=, rest::binary>>, acc), do: tokenize(rest, [{:op, :gte} | acc])
  defp tokenize(<<?<, ?=, rest::binary>>, acc), do: tokenize(rest, [{:op, :lte} | acc])
  defp tokenize(<<?=, rest::binary>>, acc), do: tokenize(rest, [{:op, :eq} | acc])
  defp tokenize(<<?>, rest::binary>>, acc), do: tokenize(rest, [{:op, :gt} | acc])
  defp tokenize(<<?<, rest::binary>>, acc), do: tokenize(rest, [{:op, :lt} | acc])

  defp tokenize(<<quote, rest::binary>>, acc) when quote in [?", ?'] do
    case :binary.split(rest, <<quote>>) do
      [value, rest] -> tokenize(rest, [{:string, value} | acc])
      [_] -> {:error, "unterminated string"}
    end
  end

  defp tokenize(input, acc) do
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*|-?\d+(?:\.\d+)?)/, input) do
      [matched, word] ->
        rest = binary_part(input, byte_size(matched), byte_size(input) - byte_size(matched))
        tokenize(rest, [token(word) | acc])

      nil ->
        {:error, "unexpected character #{inspect(String.first(input))}"}
    end
  end

  defp token(word) when word in ~w(AND OR NOT), do: {:keyword, String.downcase(word)}
  defp token(word) when word in ~w(ORDER BY ASC DESC LIMIT), do: {:keyword, String.downcase(word)}

  defp token(word),
    do:
      if(Regex.match?(~r/^-?\d+$/, word),
        do: {:number, String.to_integer(word)},
        else: {:word, word}
      )

  # ---------------------------------------------------------------------------
  # Parser: OR < AND < NOT < primary
  # ---------------------------------------------------------------------------

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens) do
      continue_or(left, rest)
    end
  end

  defp continue_or(left, [{:keyword, "or"} | rest]) do
    with {:ok, right, rest} <- parse_and(rest) do
      continue_or({:or, left, right}, rest)
    end
  end

  defp continue_or(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens) do
      continue_and(left, rest)
    end
  end

  defp continue_and(left, [{:keyword, "and"} | rest]) do
    with {:ok, right, rest} <- parse_not(rest) do
      continue_and({:and, left, right}, rest)
    end
  end

  defp continue_and(left, rest), do: {:ok, left, rest}

  defp parse_not([{:keyword, "not"} | rest]) do
    with {:ok, inner, rest} <- parse_not(rest), do: {:ok, {:not, inner}, rest}
  end

  defp parse_not(tokens), do: parse_primary(tokens)

  defp parse_primary([:lparen | rest]) do
    with {:ok, inner, rest} <- parse_or(rest),
         {:ok, rest} <- expect(rest, :rparen) do
      {:ok, inner, rest}
    end
  end

  defp parse_primary([{:word, field} | rest]) do
    with {:ok, field} <- validate_field(field),
         {:ok, op, rest} <- parse_operator(rest),
         {:ok, value, rest} <- parse_value(field, rest) do
      {:ok, {:cmp, field, op, value}, rest}
    end
  end

  defp parse_primary([]), do: {:error, "unexpected end of query"}
  defp parse_primary([token | _]), do: {:error, "unexpected token #{inspect(token)}"}

  defp parse_operator([{:op, op} | rest]), do: {:ok, op, rest}
  defp parse_operator(_), do: {:error, "expected an operator (=, !=, ~, >, <, >=, <=)"}

  defp parse_value(field, [{:string, value} | rest]), do: validate_value(field, value, rest)
  defp parse_value(field, [{:number, value} | rest]), do: validate_value(field, value, rest)
  defp parse_value(field, [{:word, value} | rest]), do: validate_value(field, value, rest)
  defp parse_value(_field, _), do: {:error, "expected a value"}

  defp validate_field(field) do
    case Map.fetch(@fields, String.downcase(field)) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "unknown field #{inspect(field)}"}
    end
  end

  defp validate_value(field, value, rest) when field in @text_fields do
    {:ok, to_string(value), rest}
  end

  defp validate_value(field, value, rest) when field in @date_fields do
    case parse_date(to_string(value)) do
      {:ok, datetime} ->
        {:ok, datetime, rest}

      :error ->
        {:error, "invalid date #{inspect(value)}; use YYYY-MM-DD or an ISO 8601 timestamp"}
    end
  end

  defp validate_value(field, value, rest) when field in [:id, :version, :ancestor, :parent] do
    case integer(value) do
      {:ok, number} -> {:ok, number, rest}
      :error -> {:error, "#{field} expects a number"}
    end
  end

  defp validate_value(_field, value, rest), do: {:ok, to_string(value), rest}

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} ->
        {:ok, DateTime.new!(date, ~T[00:00:00], "Etc/UTC")}

      {:error, _} ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          _ -> :error
        end
    end
  end

  defp integer(value) when is_integer(value), do: {:ok, value}

  defp integer(value) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> {:ok, number}
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # ORDER BY / LIMIT
  # ---------------------------------------------------------------------------

  defp parse_suffix(tokens) do
    with {:ok, order_by, rest} <- parse_order(tokens),
         {:ok, limit, rest} <- parse_limit(rest) do
      if rest == [], do: {:ok, order_by, limit}, else: {:error, "unexpected trailing tokens"}
    end
  end

  defp parse_order([{:keyword, "order"}, {:keyword, "by"}, {:word, field} | rest]) do
    case Map.fetch(@order_atoms, String.downcase(field)) do
      :error ->
        {:error, "cannot order by #{inspect(field)}"}

      {:ok, atom} ->
        {direction, rest} =
          case rest do
            [{:keyword, "asc"} | rest] -> {:asc, rest}
            [{:keyword, "desc"} | rest] -> {:desc, rest}
            rest -> {:desc, rest}
          end

        {:ok, {atom, direction}, rest}
    end
  end

  defp parse_order([{:keyword, "order"} | _]),
    do: {:error, "expected ORDER BY <field> [ASC|DESC]"}

  defp parse_order(rest), do: {:ok, nil, rest}

  defp parse_limit([{:keyword, "limit"}, {:number, limit} | rest])
       when limit > 0 and limit <= 500,
       do: {:ok, limit, rest}

  defp parse_limit([{:keyword, "limit"} | _]),
    do: {:error, "LIMIT expects a number between 1 and 500"}

  defp parse_limit(rest), do: {:ok, nil, rest}

  defp expect([:rparen | rest], :rparen), do: {:ok, rest}
  defp expect(_, :rparen), do: {:error, "expected )"}

  @doc "Fields that can be ordered by."
  def order_fields, do: Map.keys(@order_atoms)
end
