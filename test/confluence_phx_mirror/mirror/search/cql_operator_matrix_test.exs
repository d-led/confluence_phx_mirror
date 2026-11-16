defmodule ConfluencePhxMirror.Mirror.Search.CqlOperatorMatrixTest do
  @moduledoc """
  Every question the parser accepts is a question the builder can answer.

  The parser's field table and `Mirror.Search`'s clauses are two halves of one
  promise, and when they disagree the failure is a raise in the middle of a
  reader's search rather than a sentence saying what went wrong. `ancestor != 1000`
  and `version ~ 3` were exactly that: accepted, then raised — one of them inside
  the operator translation, where the reader sees a stack trace instead of a
  refusal.

  So this asks the parser about every field and every operator it knows, and runs
  everything it accepted. A pair the parser refuses is a pair nobody has to run.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :postgres_only

  @moduletag :empty_mirror

  alias ConfluencePhxMirror.Mirror.Search
  alias ConfluencePhxMirror.Mirror.Search.CQL

  @fields ~w(text title space label type status creator ancestor parent id version created lastmodified)

  @operators [
    {"=", "="},
    {"!=", "!="},
    {"~", "~"},
    {"!~", "!~"},
    {">", ">"},
    {"<", "<"},
    {">=", ">="},
    {"<=", "<="},
    {"IN", "IN"},
    {"NOT IN", "NOT IN"}
  ]

  # A value each field can read, so a query is about the operator rather than
  # about whether the operand parses.
  @values %{
    "text" => ~s("a word"),
    "title" => ~s("a title"),
    "space" => "ENG",
    "label" => "architecture",
    "type" => "page",
    "status" => "current",
    "creator" => ~s("Jane Doe"),
    "ancestor" => "1000",
    "parent" => "1000",
    "id" => "1002",
    "version" => "3",
    "created" => ~s("2026-01-01"),
    "lastmodified" => ~s("2026-01-01")
  }

  test "every question the parser accepts is one the builder can answer" do
    for field <- @fields, {operator, _label} <- @operators do
      query = "#{field} #{operator} #{@values[field]}"

      case CQL.parse(query) do
        {:error, _refusal} ->
          :ok

        {:ok, _parsed} ->
          assert answerable?(query), "#{query} was accepted by the parser and could not be run"
      end
    end
  end

  test "a field says which operators it takes instead of raising" do
    assert {:error, refusal} = CQL.parse("ancestor != 1000")
    assert refusal =~ "ancestor"
    assert refusal =~ "IN"

    assert {:error, refusal} = CQL.parse("version ~ 3")
    assert refusal =~ "version"
    assert refusal =~ ">="
  end

  # The builder answers with a result or with a refusal, and never by raising:
  # the one thing a reader cannot be handed is a stack trace.
  defp answerable?(query) do
    match?({tag, _} when tag in [:ok, :error], Search.search(query))
  end
end
