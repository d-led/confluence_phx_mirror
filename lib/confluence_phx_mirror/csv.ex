defmodule ConfluencePhxMirror.Csv do
  @moduledoc """
  One CSV row, in the shape RFC 4180 asks for.

  A field is quoted when it holds a comma, a quote or a newline, and a quote
  inside it is doubled. Anything else stays as it is, so numbers and timestamps
  stay readable in a spreadsheet.

  Both exports of the log tables — the audit log and the sync runs — write
  through here, so a page title with a comma breaks neither of them.
  """

  @doc "The fields as one CSV line, without the trailing newline."
  @spec encode_row([term()]) :: iodata()
  def encode_row(values), do: Enum.map_join(values, ",", &field/1)

  defp field(nil), do: ""

  defp field(value) when is_binary(value) do
    if String.contains?(value, [",", "\"", "\n", "\r"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end

  defp field(value), do: to_string(value)
end
