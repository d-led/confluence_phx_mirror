defmodule ConfluencePhxMirrorWeb.Api.V1.PageController do
  @moduledoc "Page endpoints: listing, single page, children, labels, attachments, comments, backlinks."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.Api.V1.Presenter

  def index(conn, params) do
    {start, limit} = pagination(params)
    space_key = params["key"] || params["spaceKey"]

    case fetch_pages(space_key) do
      {:ok, all_pages} ->
        pages = Authorization.readable_pages(conn.assigns.current_scope, all_pages)

        items =
          pages
          |> Enum.drop(start)
          |> Enum.take(limit)
          |> Enum.map(&Presenter.summary/1)

        json(
          conn,
          Presenter.list(items,
            start: start,
            limit: limit,
            total: length(pages),
            path: request_path(conn)
          )
        )

      {:error, reason} ->
        error(conn, 404, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    with_page(conn, id, fn page -> json(conn, Presenter.page(page)) end)
  end

  def children(conn, %{"id" => id}) do
    with_page(conn, id, fn page ->
      items = page |> Mirror.children() |> Enum.map(&Presenter.summary/1)

      json(
        conn,
        Presenter.list(items,
          start: 0,
          limit: length(items),
          total: length(items),
          path: request_path(conn)
        )
      )
    end)
  end

  def ancestors(conn, %{"id" => id}) do
    with_page(conn, id, fn page ->
      items = page |> Mirror.ancestor_pages() |> Enum.map(&Presenter.summary/1)

      json(
        conn,
        Presenter.list(items,
          start: 0,
          limit: length(items),
          total: length(items),
          path: request_path(conn)
        )
      )
    end)
  end

  def labels(conn, %{"id" => id}) do
    with_page(conn, id, fn page ->
      results =
        page.labels
        |> Enum.map(&%{"name" => &1, "prefix" => "global"})

      json(conn, %{
        "results" => results,
        "size" => length(results),
        "_links" => %{"base" => ConfluencePhxMirrorWeb.Endpoint.url()}
      })
    end)
  end

  def attachments(conn, %{"id" => id}) do
    with_page(conn, id, fn page ->
      items =
        page
        |> Mirror.attachments()
        |> Enum.map(&%{&1 | page: page})
        |> Enum.map(&Presenter.attachment/1)

      json(
        conn,
        Presenter.list(items,
          start: 0,
          limit: length(items),
          total: length(items),
          path: request_path(conn)
        )
      )
    end)
  end

  def comments(conn, %{"id" => id}) do
    with_page(conn, id, fn page ->
      items = page |> Mirror.comments() |> Enum.map(&Presenter.comment/1)

      json(
        conn,
        Presenter.list(items,
          start: 0,
          limit: length(items),
          total: length(items),
          path: request_path(conn)
        )
      )
    end)
  end

  def backlinks(conn, %{"id" => id}) do
    with_page(conn, id, fn page ->
      items = page |> Mirror.backlinks() |> Enum.map(&Presenter.summary/1)

      json(
        conn,
        Presenter.list(items,
          start: 0,
          limit: length(items),
          total: length(items),
          path: request_path(conn)
        )
      )
    end)
  end

  def by_path(conn, params) do
    with {id, ""} <- Integer.parse(to_string(params["id"])),
         {:ok, page} <- Mirror.find_page_by_path(params["space"] || params["spaceKey"], id),
         true <- readable?(conn, page) do
      json(conn, Presenter.page(page))
    else
      _ -> error(conn, 404, "Page is not mirrored.")
    end
  end

  defp fetch_pages(nil), do: {:ok, Mirror.list_all_pages()}

  defp fetch_pages(space_key) do
    case Mirror.find_space(space_key) do
      {:ok, space} -> {:ok, Mirror.list_pages(space.id)}
      {:error, :not_found} -> {:error, "Space #{space_key} is not mirrored."}
    end
  end

  defp with_page(conn, id, fun) do
    with {id, ""} <- Integer.parse(to_string(id)),
         {:ok, page} <- Mirror.find_page(id),
         true <- readable?(conn, page) do
      fun.(page)
    else
      _ -> error(conn, 404, "Page #{id} is not mirrored.")
    end
  end

  # The API answers as the caller: a page the reader may not open is not
  # mirrored as far as that reader is concerned, exactly like the HTML view.
  defp readable?(conn, page), do: Authorization.can_read_page?(conn.assigns.current_scope, page)

  defp pagination(params) do
    start = parse_int(params["start"], 0)
    limit = params["limit"] |> parse_int(25) |> min(100) |> max(1)
    {max(start, 0), limit}
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {number, _} -> number
      :error -> default
    end
  end

  defp request_path(conn), do: "/" <> Enum.join(conn.path_info, "/")

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: "not_found", message: message})
  end

  @doc false
  def page_url(page),
    do: URLs.page_path(page.space.key, page.confluence_id, page.slug)
end
