defmodule ConfluencePhxMirror.Mcp.Args do
  @moduledoc """
  Reads a tool call's arguments into the types the mirror's functions expect.

  MCP arguments arrive as a JSON object with whatever types the client decided
  to send — a number may be a string, a boolean may be absent. Each reader
  returns `{:ok, value}` or `{:error, message}`, and the message names the
  argument and what was expected, because it is shown to the model that made
  the call and is the best chance it has to correct itself.
  """

  @type result(t) :: {:ok, t} | {:error, String.t()}

  @doc "A required, non-blank string."
  @spec required(map(), String.t()) :: result(String.t())
  def required(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "`#{key}` is required."}
          trimmed -> {:ok, trimmed}
        end

      value when is_integer(value) ->
        {:ok, Integer.to_string(value)}

      _missing ->
        {:error, "`#{key}` is required."}
    end
  end

  @doc "An optional string; `{:ok, nil}` when absent or blank."
  @spec optional(map(), String.t()) :: result(String.t() | nil)
  def optional(args, key) do
    case args[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      value when is_integer(value) ->
        {:ok, Integer.to_string(value)}

      _missing ->
        {:ok, nil}
    end
  end

  @doc """
  An optional integer, clamped to `:min`..`:max`.

  A client that sends `limit: 500` gets the maximum rather than an error: the
  caller's intent is clear, and failing the call over it wastes a turn.
  """
  @spec integer(map(), String.t(), keyword()) :: result(integer())
  def integer(args, key, opts) do
    default = Keyword.fetch!(opts, :default)
    min = Keyword.get(opts, :min, 1)
    max = Keyword.get(opts, :max, 100)

    case args[key] do
      nil ->
        {:ok, default}

      value ->
        case parse_integer(value) do
          {:ok, number} -> {:ok, number |> max(min) |> min(max)}
          :error -> {:error, "`#{key}` must be an integer between #{min} and #{max}."}
        end
    end
  end

  @doc "An optional boolean, `default` when absent."
  @spec boolean(map(), String.t(), boolean()) :: result(boolean())
  def boolean(args, key, default) do
    case args[key] do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _other -> {:error, "`#{key}` must be true or false."}
    end
  end

  @doc "An optional value from a fixed set; unknown values are refused."
  @spec one_of(map(), String.t(), [String.t()], String.t()) :: result(String.t())
  def one_of(args, key, allowed, default) do
    case args[key] do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        if value in allowed do
          {:ok, value}
        else
          {:error, "`#{key}` must be one of: #{Enum.join(allowed, ", ")}."}
        end

      _other ->
        {:error, "`#{key}` must be one of: #{Enum.join(allowed, ", ")}."}
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _not_a_number -> :error
    end
  end

  defp parse_integer(_value), do: :error
end
