defmodule ConfluencePhxMirrorWeb.PageController do
  use ConfluencePhxMirrorWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
