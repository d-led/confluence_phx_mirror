defmodule ConfluencePhxMirrorWeb.Api.V1.SpaceController do
  @moduledoc "Space endpoints."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.Api.V1.Presenter

  def index(conn, _params) do
    scope = conn.assigns.current_scope

    spaces =
      Mirror.spaces_with_counts()
      |> Enum.filter(fn {space, _count} -> Authorization.can_read_space?(scope, space) end)

    json(conn, %{
      "results" =>
        Enum.map(spaces, fn {space, count} ->
          Presenter.space(space) |> Map.put("pageCount", count)
        end),
      "size" => length(spaces),
      "_links" => %{"base" => ConfluencePhxMirrorWeb.Endpoint.url()}
    })
  end

  def show(conn, %{"key" => key}) do
    with {:ok, space} <- Mirror.find_space(key),
         true <- Authorization.can_read_space?(conn.assigns.current_scope, space) do
      json(conn, Presenter.space(space))
    else
      _ ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found", message: "Space #{key} is not mirrored."})
    end
  end
end
