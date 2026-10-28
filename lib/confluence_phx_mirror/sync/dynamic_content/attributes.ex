defmodule ConfluencePhxMirror.Sync.DynamicContent.Attributes do
  @moduledoc """
  Reading a marker's attributes, in the two shapes macros actually use.

  Confluence writes macro parameters as HTML attributes, so everything arrives as
  a string: `data-labels="runbook, incident"`, `data-limit="25"`. These helpers
  turn "a comma-separated list" and "a number within a sane range" into values a
  renderer can work with, and treat a missing or unusable attribute as "the
  default" instead of an error — a macro Confluence accepted should render, not
  disappear because a number is empty.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.Renderer

  @doc """
  The attribute as a trimmed list of non-empty values.

      iex> list(%{"labels" => "runbook, incident"}, "labels")
      ["runbook", "incident"]
  """
  @spec list(Renderer.attrs(), String.t()) :: [String.t()]
  def list(attrs, name) do
    attrs
    |> Map.get(name, "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  The attribute as a positive number inside `range`, or `default`.

      iex> int(%{"limit" => "5"}, "limit", 10, 1..50)
      5
  """
  @spec int(Renderer.attrs(), String.t(), pos_integer(), Range.t()) :: pos_integer()
  def int(attrs, name, default, range) do
    with value when is_binary(value) <- Map.get(attrs, name),
         {number, ""} <- Integer.parse(String.trim(value)),
         true <- number in range do
      number
    else
      _ -> default
    end
  end
end
