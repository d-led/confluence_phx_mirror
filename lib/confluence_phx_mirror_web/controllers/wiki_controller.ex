defmodule ConfluencePhxMirrorWeb.WikiController do
  @moduledoc """
  Confluence's links carry a `/wiki` prefix that the mirror does not use.

  A published Confluence page URL is

      https://site.atlassian.net/wiki/spaces/KEY/pages/ID/Title+With+Pluses

  and the mirror serves the same page at

      https://mirror/spaces/KEY/pages/ID/title-with-hyphens

  so pointing a Confluence link at the mirror is a change of host and nothing
  else. This drops the prefix and lets the normal routes resolve the rest —
  including the slug, which the page controller compares with the canonical one
  and redirects when it differs. A reader pasting either form therefore lands on
  the same page, and there is still exactly one canonical URL per page.

  `/wiki/rest/api/...` is the Confluence-compatible API and is routed before
  this, so it never comes here.
  """

  use ConfluencePhxMirrorWeb, :controller

  def without_wiki(conn, %{"path" => segments}) do
    path = "/" <> Enum.join(segments, "/")

    conn
    |> put_status(:found)
    |> redirect(to: with_query(path, conn.query_string))
  end

  def without_wiki(conn, _params) do
    conn
    |> put_status(:found)
    |> redirect(to: with_query("/", conn.query_string))
  end

  defp with_query(path, ""), do: path
  defp with_query(path, query), do: path <> "?" <> query
end
