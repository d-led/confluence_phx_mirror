defmodule ConfluencePhxMirrorWeb.ApiDocsHTML do
  @moduledoc "Templates for the API description page."

  use ConfluencePhxMirrorWeb, :html

  alias ConfluencePhxMirrorWeb.Endpoint

  embed_templates "api_docs_html/*"

  defp slug(tag) do
    tag
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
  end

  defp schema_type(%{"type" => type, "enum" => values}) when is_list(values),
    do: "#{type} · one of #{Enum.join(values, ", ")}"

  defp schema_type(%{"type" => type}), do: type
  defp schema_type(_schema), do: "any"

  defp has_token?(%{"security" => [_ | _]}), do: true
  defp has_token?(_operation), do: false

  # Descriptions are markdown (`code`, mostly), which is right for the document
  # and wrong on a page: split on the backticks and style the odd parts as code.
  defp inline_code(nil), do: []

  defp inline_code(text) do
    text
    |> String.split("`")
    |> Enum.with_index()
    |> Enum.map(fn {part, index} -> {part, rem(index, 2) == 1} end)
  end
end
