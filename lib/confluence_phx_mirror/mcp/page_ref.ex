defmodule ConfluencePhxMirror.Mcp.PageRef do
  @moduledoc """
  The ways a caller may name one page.

  A Confluence page id is a number, but the thing a person pastes is almost
  always the URL it appears in, so both are accepted — the id in
  `/spaces/KEY/pages/123/Title`, the `pageId` of the old
  `viewpage.action` shape, and a bare number. Anything else (`/wiki/x/N4CIO`,
  a tiny link) needs the site to resolve, and the mirror does not have the
  site's redirect table: it says so instead of guessing.
  """

  @type ref :: {:id, integer()}

  @doc "Parses an id or a page URL."
  @spec parse(term()) :: {:ok, ref()} | :error
  def parse(value) when is_integer(value), do: {:ok, {:id, value}}

  def parse(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {id, ""} -> {:ok, {:id, id}}
      _not_a_number -> from_url(value)
    end
  end

  def parse(_value), do: :error

  defp from_url(value) do
    case Regex.run(~r{/pages/(\d+)}, value) || Regex.run(~r{[?&]pageId=(\d+)}, value) do
      [_, id] -> {:ok, {:id, String.to_integer(id)}}
      nil -> :error
    end
  end
end
