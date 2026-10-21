defmodule ConfluencePhxMirrorWeb.PeopleHTML do
  @moduledoc "Templates for the people directory."

  use ConfluencePhxMirrorWeb, :html

  import ConfluencePhxMirrorWeb.MirrorComponents

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.Time

  embed_templates "people_html/*"

  defp author_path(%{account_id: nil}), do: URLs.people_path()
  defp author_path(%{account_id: account_id}), do: URLs.person_path(account_id)

  defp initials(name) do
    name
    |> to_string()
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.map(&String.first/1)
    |> Enum.take(2)
    |> Enum.join()
    |> String.upcase()
  end
end
