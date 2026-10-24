defmodule ConfluencePhxMirror.Mirror.Search.TextQuery do
  @moduledoc """
  Parses a reader's query into a Postgres `tsquery`.

  It is deliberately not CQL: there are no field names, only words and boolean
  structure. Plain words are ANDed, `OR`/`AND`/`NOT` (uppercase) combine
  groups, parentheses group, `"quoted phrases"` stay phrases and a leading `-`
  excludes a term — close to what people expect from a search box.

  Unquoted words match by prefix (`architect` finds “architecture”); quoted
  phrases are exact; a star on the end of a word (`architect*`) says the same
  prefix match is all the reader wants — `Mirror.Search.text/2` reads it as “do
  not look inside other words”. If the input is malformed (unclosed quote or
  parenthesis) the caller falls back to Postgres' forgiving
  `websearch_to_tsquery`.
  """

  @type ast ::
          {:terms, [String.t()]}
          | {:phrase, [String.t()]}
          | {:and, ast(), ast()}
          | {:or, ast(), ast()}
          | {:not, ast()}

  @type token ::
          {:term, [String.t()]}
          | {:phrase, [String.t()]}
          | :and
          | :or
          | :not
          | :lparen
          | :rparen

  @doc "Returns a Postgres tsquery string and the words to highlight."
  @spec parse(String.t()) :: {:ok, String.t(), [String.t()]} | :empty | :error
  def parse(input) when is_binary(input) do
    with true <- String.trim(input) != "",
         {:ok, tokens} <- tokenize(String.trim(input), []),
         {:ok, ast, []} <- parse_or(tokens) do
      {:ok, to_tsquery(ast), terms(ast)}
    else
      false -> :empty
      _ -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Tokenizer
  # ---------------------------------------------------------------------------

  defp tokenize("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokenize(<<char::utf8, rest::binary>>, acc)
       when char in [?\s, ?\t, ?\n, ?\r],
       do: tokenize(rest, acc)

  defp tokenize(<<"(", rest::binary>>, acc), do: tokenize(rest, [:lparen | acc])
  defp tokenize(<<")", rest::binary>>, acc), do: tokenize(rest, [:rparen | acc])

  defp tokenize(<<"\"", rest::binary>>, acc) do
    case :binary.split(rest, "\"") do
      [phrase, rest] ->
        case lexemes(phrase) do
          {:ok, words} -> tokenize(rest, [{:phrase, words} | acc])
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp tokenize(<<"-", rest::binary>>, acc), do: tokenize(rest, [:not | acc])

  defp tokenize(input, acc) do
    {word, rest} = take_word(input, "")

    case word do
      "" ->
        :error

      "AND" ->
        tokenize(rest, [:and | acc])

      "OR" ->
        tokenize(rest, [:or | acc])

      "NOT" ->
        tokenize(rest, [:not | acc])

      word ->
        case lexemes(word) do
          {:ok, words} -> tokenize(rest, [{:term, words} | acc])
          :error -> :error
        end
    end
  end

  defp take_word("", acc), do: {acc, ""}

  defp take_word(<<char::utf8, _rest::binary>> = input, acc)
       when char in [?\s, ?\t, ?\n, ?\r, ?(, ?), ?"],
       do: {acc, input}

  defp take_word(<<char::utf8, rest::binary>>, acc), do: take_word(rest, acc <> <<char::utf8>>)

  defp lexemes(text) do
    words =
      text
      |> String.downcase()
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.map(&String.replace(&1, ~r/^[^\p{L}\p{N}_]+|[^\p{L}\p{N}_]+$/u, ""))
      |> Enum.reject(&(&1 == ""))

    if words == [], do: :error, else: {:ok, words}
  end

  # ---------------------------------------------------------------------------
  # Parser: OR < AND (implicit too) < NOT < primary
  # ---------------------------------------------------------------------------

  defp parse_or(tokens) do
    with {:ok, left, rest} <- parse_and(tokens), do: continue_or(left, rest)
  end

  defp continue_or(left, [:or | rest]) do
    with {:ok, right, rest} <- parse_and(rest), do: continue_or({:or, left, right}, rest)
  end

  defp continue_or(left, rest), do: {:ok, left, rest}

  defp parse_and(tokens) do
    with {:ok, left, rest} <- parse_not(tokens), do: continue_and(left, rest)
  end

  defp continue_and(left, [:and | rest]) do
    with {:ok, right, rest} <- parse_not(rest), do: continue_and({:and, left, right}, rest)
  end

  defp continue_and(left, [{kind, _words} | _] = rest) when kind in [:term, :phrase] do
    with {:ok, right, rest} <- parse_not(rest), do: continue_and({:and, left, right}, rest)
  end

  defp continue_and(left, [:not | _] = rest) do
    with {:ok, right, rest} <- parse_not(rest), do: continue_and({:and, left, right}, rest)
  end

  defp continue_and(left, [:lparen | _] = rest) do
    with {:ok, right, rest} <- parse_not(rest), do: continue_and({:and, left, right}, rest)
  end

  defp continue_and(left, rest), do: {:ok, left, rest}

  defp parse_not([:not | rest]) do
    with {:ok, inner, rest} <- parse_not(rest), do: {:ok, {:not, inner}, rest}
  end

  defp parse_not(tokens), do: parse_primary(tokens)

  defp parse_primary([:lparen | rest]) do
    with {:ok, inner, rest} <- parse_or(rest),
         {:ok, rest} <- expect_rparen(rest) do
      {:ok, inner, rest}
    end
  end

  defp parse_primary([{:term, words} | rest]), do: {:ok, {:terms, words}, rest}
  defp parse_primary([{:phrase, words} | rest]), do: {:ok, {:phrase, words}, rest}
  defp parse_primary(_tokens), do: :error

  defp expect_rparen([:rparen | rest]), do: {:ok, rest}
  defp expect_rparen(_tokens), do: :error

  # ---------------------------------------------------------------------------
  # tsquery rendering
  # ---------------------------------------------------------------------------

  defp to_tsquery({:and, left, right}),
    do: "(" <> to_tsquery(left) <> " & " <> to_tsquery(right) <> ")"

  defp to_tsquery({:or, left, right}),
    do: "(" <> to_tsquery(left) <> " | " <> to_tsquery(right) <> ")"

  defp to_tsquery({:not, inner}), do: "!(" <> to_tsquery(inner) <> ")"
  defp to_tsquery({:terms, [word]}), do: lexeme(word) <> ":*"
  defp to_tsquery({:terms, words}), do: phrase(words, :prefix)
  defp to_tsquery({:phrase, words}), do: phrase(words, :exact)

  defp phrase(words, mode) do
    last = length(words) - 1

    words
    |> Enum.with_index()
    |> Enum.map_join(" <-> ", fn {word, index} ->
      suffix = if mode == :prefix and index == last, do: ":*", else: ""
      lexeme(word) <> suffix
    end)
  end

  defp lexeme(word), do: "'" <> String.replace(word, "'", "''") <> "'"

  defp terms(ast) do
    ast
    |> collect_terms([])
    |> Enum.uniq()
  end

  defp collect_terms({:and, left, right}, acc), do: collect_terms(right, collect_terms(left, acc))
  defp collect_terms({:or, left, right}, acc), do: collect_terms(right, collect_terms(left, acc))
  defp collect_terms({:not, inner}, acc), do: collect_terms(inner, acc)
  defp collect_terms({:terms, words}, acc), do: words ++ acc
  defp collect_terms({:phrase, words}, acc), do: words ++ acc
end
