defmodule ConfluencePhxMirrorWeb.ThemeController do
  @moduledoc """
  Persists the reader's variant — `system`, `light` or `dark` — in a cookie and
  returns to the page they came from. No JavaScript, no flicker, works with
  caching. The theme itself is the administrator's choice, not the reader's.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirrorWeb.Skins

  def set(conn, %{"name" => name} = params) do
    variant = if Skins.variant?(name), do: name, else: "system"

    conn
    |> put_resp_cookie("mirror_theme", variant,
      max_age: 365 * 24 * 60 * 60,
      same_site: "Lax",
      http_only: true,
      path: "/"
    )
    |> redirect(to: return_path(conn, params["redirect"]))
  end

  # Only same-site absolute paths are allowed, so this cannot be abused as an
  # open redirect.
  defp return_path(conn, redirect) when is_binary(redirect) do
    case URI.parse(redirect) do
      %URI{scheme: nil, host: nil, path: "/" <> _ = path} -> path
      _ -> referer_path(conn)
    end
  end

  defp return_path(conn, _redirect), do: referer_path(conn)

  defp referer_path(conn) do
    conn
    |> get_req_header("referer")
    |> List.first()
    |> case do
      nil ->
        ~p"/"

      referer ->
        case URI.parse(referer) do
          %URI{path: "/" <> _ = path} -> path
          _ -> ~p"/"
        end
    end
  end
end
