defmodule ConfluencePhxMirror.Mirror.Search.CQL do
  @moduledoc """
  A small, strict CQL parser.

  Confluence's CQL is large; the mirror supports the subset that makes sense for
  a read-only cache — the operators, fields and functions that can be answered
  from what a sync stored, and an honest error for the rest:

      space = ENG AND label = architecture
      text ~ "rate limit" OR title ~ "release"
      label in (architecture, design) AND space not in (OLD, ARCHIVE)
      title !~ draft
      lastmodified > now("-4w") AND created < startOfYear()
      type = blogpost ORDER BY lastmodified DESC, title ASC LIMIT 10

  Supported operators: `=`, `!=`, `>`, `>=`, `<`, `<=`, `~`, `!~`, `IN`,
  `NOT IN`. Supported fields: `text`, `title`, `space`, `label`, `type`,
  `status`, `creator`, `ancestor`, `parent`, `id`, `version`, `created`,
  `lastmodified`. Supported functions: `now()`, `startOfDay()`, `endOfDay()` and
  their week, month and year siblings, each with an optional `"-7d"` style
  increment (`Mirror.Search.CQL.Functions`).

  Two things are refused rather than approximated, because a mirror answers a
  query once for every reader: `currentUser()` and the other user-specific
  functions, and any field the sync never stored.

  The parser returns an AST; `ConfluencePhxMirror.Mirror.Search` compiles it to
  parameterised Ecto queries.
  """

  alias ConfluencePhxMirror.Mirror.Search.CQL.Functions

  defmodule Query do
    @moduledoc "Parsed CQL query."
    @enforce_keys [:filter]
    defstruct filter: nil, order_by: nil, limit: nil

    @type t :: %__MODULE__{
            filter: term(),
            order_by: [{atom(), :asc | :desc}] | nil,
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

  @operators "=, !=, ~, !~, >, <, >=, <=, IN, NOT IN"

  # Fields Confluence documents that a read-only mirror cannot answer, with the
  # reason — telling a reader "unknown field" for `watcher` would send them
  # looking for a typo that is not there.
  @unsupported %{
    "mention" => "the sync keeps authors, not the people a page mentions",
    "watcher" => "watching is per person, and the mirror answers once for every reader",
    "favourite" => "favourites are per person, and the mirror answers once for every reader",
    "favorite" => "favourites are per person, and the mirror answers once for every reader",
    "pagestatus" => "page status is not mirrored",
    "macro" => "the mirror resolves the macros it knows and indexes no macro names",
    "container" => "the mirror has no container field; use parent or ancestor",
    "space.title" => "narrow by space key; a space's title is searchable as text",
    "space.type" => "the mirror does not store space types",
    "space.category" => "space categories are not mirrored",
    "user" => "user search is not mirrored",
    "user.fullname" => "user search is not mirrored",
    "user.accountid" => "user search is not mirrored"
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
  defp tokenize(<<?!, ?~, rest::binary>>, acc), do: tokenize(rest, [{:op, :not_contains} | acc])
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
    case Regex.run(~r/^([A-Za-z_][A-Za-z0-9_.]*|-?\d+(?:\.\d+)?)/, input) do
      [matched, word] ->
        rest = binary_part(input, byte_size(matched), byte_size(input) - byte_size(matched))
        tokenize(rest, [token(word) | acc])

      nil ->
        {:error, "unexpected character #{inspect(String.first(input))}"}
    end
  end

  # Confluence writes its own examples in lower case (`and`, `in`, `desc`), and
  # CQL is case-insensitive about keywords and fields alike. A word that is one
  # of them says so; anything else is a value.
  defp token(word) do
    case String.downcase(word) do
      keyword when keyword in ~w(and or not in) -> {:keyword, keyword}
      keyword when keyword in ~w(order by asc desc limit) -> {:keyword, keyword}
      _ -> value(word)
    end
  end

  defp value(word) do
    if Regex.match?(~r/^-?\d+$/, word),
      do: {:number, String.to_integer(word)},
      else: {:word, word}
  end

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
         {:ok, op, rest} <- parse_operator(rest) do
      parse_operand(field, op, rest)
    end
  end

  defp parse_primary([]), do: {:error, "unexpected end of query"}
  defp parse_primary([token | _]), do: {:error, "unexpected token #{inspect(token)}"}

  defp parse_operator([{:op, op} | rest]), do: {:ok, op, rest}
  defp parse_operator([{:keyword, "not"}, {:keyword, "in"} | rest]), do: {:ok, :not_in, rest}
  defp parse_operator([{:keyword, "in"} | rest]), do: {:ok, :in, rest}
  defp parse_operator(_), do: {:error, "expected an operator (#{@operators})"}

  # `IN` names a set, everything else names one value (or a function).
  defp parse_operand(field, op, rest) when op in [:in, :not_in] do
    with {:ok, values, rest} <- parse_list(field, rest) do
      {:ok, {if(op == :in, do: :in, else: :not_in), field, values}, rest}
    end
  end

  defp parse_operand(field, op, rest) do
    with {:ok, value, rest} <- parse_value(field, rest) do
      {:ok, {:cmp, field, op, value}, rest}
    end
  end

  defp parse_list(field, [:lparen | rest]), do: parse_list_values(field, rest, [])

  defp parse_list(_field, [{:word, name}, :lparen | _rest]), do: {:error, function_error(name)}

  defp parse_list(field, _tokens),
    do: {:error, "IN expects a list in parentheses, as in #{field} IN (a, b)"}

  defp parse_list_values(field, tokens, acc) do
    with {:ok, value, rest} <- parse_list_value(field, tokens) do
      case rest do
        [:comma | rest] -> parse_list_values(field, rest, [value | acc])
        [:rparen | rest] -> {:ok, Enum.reverse([value | acc]), rest}
        _ -> {:error, "expected , or ) in the list"}
      end
    end
  end

  defp parse_list_value(_field, [{:word, name}, :lparen | _rest]) do
    {:error, function_error(name)}
  end

  defp parse_list_value(field, tokens), do: parse_scalar(field, tokens)

  defp parse_value(field, [{:word, name}, :lparen | rest]) do
    with {:ok, arguments, rest} <- parse_arguments(rest),
         {:ok, value} <- call(field, name, arguments) do
      {:ok, value, rest}
    end
  end

  defp parse_value(field, tokens), do: parse_scalar(field, tokens)

  defp parse_scalar(field, [{:string, value} | rest]), do: validate_value(field, value, rest)
  defp parse_scalar(field, [{:number, value} | rest]), do: validate_value(field, value, rest)
  defp parse_scalar(field, [{:word, value} | rest]), do: validate_value(field, value, rest)
  defp parse_scalar(_field, _tokens), do: {:error, "expected a value"}

  defp parse_arguments([:rparen | rest]), do: {:ok, [], rest}

  defp parse_arguments(tokens) do
    with {:ok, argument, rest} <- parse_argument(tokens) do
      case rest do
        [:comma | rest] ->
          with {:ok, arguments, rest} <- parse_arguments(rest) do
            {:ok, [argument | arguments], rest}
          end

        [:rparen | rest] ->
          {:ok, [argument], rest}

        _ ->
          {:error, "expected , or ) in the function arguments"}
      end
    end
  end

  defp parse_argument([{:string, value} | rest]), do: {:ok, value, rest}
  defp parse_argument([{:number, value} | rest]), do: {:ok, value, rest}
  defp parse_argument([{:word, value} | rest]), do: {:ok, value, rest}
  defp parse_argument(_tokens), do: {:error, "expected a function argument"}

  # A function is resolved here, at parse time, so "yesterday" means yesterday
  # when the query was written and not when it runs.
  defp call(field, name, arguments) do
    cond do
      Functions.user_specific?(name) ->
        {:error, function_error(name)}

      !Functions.known?(name) ->
        {:error, "unknown function #{name}()"}

      field not in @date_fields ->
        {:error, "#{name}() answers a date, so it cannot be compared with #{field}"}

      true ->
        Functions.resolve(name, arguments)
    end
  end

  defp function_error(name) do
    "#{name}() depends on who is asking, and the mirror answers a query once for " <>
      "every reader: name the value instead"
  end

  defp validate_field(field) do
    name = String.downcase(field)

    case {Map.fetch(@fields, name), Map.fetch(@unsupported, name)} do
      {{:ok, atom}, _} -> {:ok, atom}
      {_, {:ok, reason}} -> {:error, "the mirror cannot answer #{field}: #{reason}"}
      {_, :error} -> {:error, "unknown field #{inspect(field)}"}
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

  defp parse_order([{:keyword, "order"}, {:keyword, "by"} | rest]) do
    parse_order_fields(rest, [])
  end

  defp parse_order([{:keyword, "order"} | _]),
    do: {:error, "expected ORDER BY <field> [ASC|DESC]"}

  defp parse_order(rest), do: {:ok, nil, rest}

  defp parse_order_fields([{:word, field} | rest], acc) do
    with {:ok, atom} <- order_atom(field) do
      {direction, rest} = order_direction(rest)

      case rest do
        [:comma | rest] -> parse_order_fields(rest, [{atom, direction} | acc])
        rest -> {:ok, Enum.reverse([{atom, direction} | acc]), rest}
      end
    end
  end

  defp parse_order_fields(_tokens, _acc), do: {:error, "expected a field to order by"}

  defp order_atom(field) do
    case Map.fetch(@order_atoms, String.downcase(field)) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "cannot order by #{inspect(field)}"}
    end
  end

  defp order_direction([{:keyword, "asc"} | rest]), do: {:asc, rest}
  defp order_direction([{:keyword, "desc"} | rest]), do: {:desc, rest}
  defp order_direction(rest), do: {:desc, rest}

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

  @doc "Operators the mirror understands, for documentation and errors."
  def operators, do: @operators
end
