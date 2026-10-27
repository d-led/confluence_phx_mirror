defmodule ConfluencePhxMirrorWeb.Api.V1.SpaceController do
  @moduledoc """
  Spaces, and which of them this mirror imports.

  `index` and `show` answer with what is mirrored. The two writes change the
  whitelist a run imports — the deployment's `CM_SPACES` plus the keys an
  administrator added — and are administrator-only, because a removal stops a
  space being imported and the next run trashes what it holds.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Space
  alias ConfluencePhxMirror.Sync.SpaceScope
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

  @doc "Import one more space: adds a key to the whitelist a run reads."
  def create(conn, params) do
    if admin?(conn) do
      case key_from(params) do
        {:ok, key} -> add(conn, key)
        :error -> unprocessable(conn, "Give a space `key`.")
      end
    else
      forbidden(conn)
    end
  end

  @doc "Stop importing a space: takes a key back out of the runtime whitelist."
  def delete(conn, %{"key" => key}) do
    if admin?(conn) do
      drop(conn, Space.normalise_key(key))
    else
      forbidden(conn)
    end
  end

  # Naming one key on a mirror that holds every space would narrow it to that
  # key, and the next run would trash the rest. That is a decision to take
  # deliberately, starting from CM_SPACES, not as a side effect of one POST.
  defp add(conn, key) do
    if SpaceScope.wanted() == :all do
      conn
      |> put_status(:conflict)
      |> json(%{
        "error" => "imports_every_space",
        "message" => "Naming one key would narrow this mirror to that key. Set CM_SPACES first."
      })
    else
      store(conn, SpaceScope.add(key, actor(conn)), :created, fn ->
        %{"key" => Space.normalise_key(key)}
      end)
    end
  end

  defp drop(conn, key) do
    # What the next run moves is what is mirrored now; the removal itself does
    # not touch content.
    pages = mirrored_pages(key)

    store(conn, SpaceScope.remove(key, actor(conn)), :ok, fn ->
      %{
        "key" => key,
        # A key the deployment names stays in force: the variable would restore
        # it at the next boot, so the answer says so rather than pretending.
        "removed" => key not in keys_in_force(),
        "pages_awaiting_trash" => pages
      }
    end)
  end

  # The body is a function because it describes the state the write left behind,
  # not the one it started from.
  defp store(conn, {:ok, _applied}, status, body) do
    conn |> put_status(status) |> json(Map.merge(body.(), whitelist()))
  end

  defp store(conn, {:error, reason}, _status, _body) do
    unprocessable(conn, "Not saved: #{inspect(reason)}")
  end

  defp whitelist do
    case SpaceScope.wanted() do
      :all -> %{"every_space" => true, "keys" => []}
      keys -> %{"every_space" => false, "keys" => keys}
    end
  end

  defp keys_in_force do
    case SpaceScope.wanted() do
      :all -> []
      keys -> keys
    end
  end

  defp mirrored_pages(key) do
    case Mirror.spaces_by_last_sync(1, key: key) do
      [{_key, _name, _synced_at, pages}] -> pages
      [] -> 0
    end
  end

  defp key_from(params) do
    case params["key"] do
      key when is_binary(key) and key != "" -> {:ok, key}
      _missing -> :error
    end
  end

  defp admin?(conn), do: Scope.admin?(Scope.from_assigns(conn.assigns))

  defp actor(conn), do: {:user, conn.assigns.current_user}

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      "error" => "not_authorized",
      "message" => "The space whitelist is an administrator's decision."
    })
  end

  defp unprocessable(conn, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{"error" => "not_saved", "message" => message})
  end
end
