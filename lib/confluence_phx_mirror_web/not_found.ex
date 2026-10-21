defmodule ConfluencePhxMirrorWeb.NotFound do
  @moduledoc "Renders the mirror's 404 page from any reader controller."

  import Phoenix.Controller, only: [put_view: 2, render: 3]
  import Plug.Conn, only: [put_status: 2]

  def call(conn, message) do
    conn
    |> put_status(:not_found)
    |> put_view(ConfluencePhxMirrorWeb.ErrorHTML)
    |> render(:"404", message: message)
  end
end
