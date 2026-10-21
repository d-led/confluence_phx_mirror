defmodule ConfluencePhxMirrorWeb.Api.V1.SpaceController do
  @moduledoc "Space endpoints."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirrorWeb.Api.V1.Presenter

  def index(conn, _params) do
    spaces = Mirror.spaces_with_counts()

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
    case Mirror.find_space(key) do
      {:ok, space} ->
        json(conn, Presenter.space(space))

      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{error: "not_found", message: "Space #{key} is not mirrored."})
    end
  end
end
