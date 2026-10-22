defmodule ConfluencePhxMirrorWeb.SubscriptionController do
  @moduledoc "Watch / unwatch pages and spaces (e-mail notifications)."

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Notifications.Subscription

  @targets ~w(page space)

  def create(conn, %{"target_type" => target_type, "target_id" => target_id}) do
    with_user(conn, fn user ->
      with :ok <- validate_target(target_type),
           {id, ""} <- Integer.parse(to_string(target_id)),
           :ok <- authorize_target(conn, target_type, id),
           {:ok, subscription} <- Notifications.subscribe(user, target_type, id) do
        Audit.log({:user, user}, Subscription.audit_event_created(subscription, user))

        conn
        |> put_flash(:info, "You will get an e-mail when this #{target_type} changes.")
        |> redirect(to: back(conn))
      else
        _ ->
          conn
          |> put_flash(:error, "Could not create the subscription.")
          |> redirect(to: back(conn))
      end
    end)
  end

  def delete(conn, %{"target_type" => target_type, "target_id" => target_id}) do
    with_user(conn, fn user ->
      with :ok <- validate_target(target_type),
           {id, ""} <- Integer.parse(to_string(target_id)) do
        Notifications.unsubscribe(user, target_type, id)
        Audit.log({:user, user}, Subscription.audit_event_deleted(user, target_type, id))

        conn
        |> put_flash(:info, "Subscription removed.")
        |> redirect(to: back(conn))
      else
        _ -> conn |> put_flash(:error, "Invalid subscription.") |> redirect(to: back(conn))
      end
    end)
  end

  defp with_user(conn, fun) do
    case conn.assigns[:current_user] do
      %User{} = user -> fun.(user)
      _ -> conn |> put_flash(:error, "Please sign in first.") |> redirect(to: ~p"/session")
    end
  end

  defp validate_target(target_type) when target_type in @targets, do: :ok
  defp validate_target(_target_type), do: {:error, :invalid_target}

  # You may only watch something you may read — and the same refusal covers "no
  # such page", so the flash does not say which of the two it was.
  defp authorize_target(conn, "page", id) do
    with {:ok, page} <- Mirror.find_page_by_local_id(id),
         true <- Authorization.can_read_page?(scope(conn), page) do
      :ok
    else
      _ -> {:error, :not_readable}
    end
  end

  defp authorize_target(conn, "space", id) do
    with {:ok, space} <- Mirror.find_space_by_id(id),
         true <- Authorization.can_read_space?(scope(conn), space) do
      :ok
    else
      _ -> {:error, :not_readable}
    end
  end

  defp scope(conn), do: Scope.for_user(conn.assigns[:current_user])

  # Only the path of the referer is used, so this cannot become an open redirect.
  defp back(conn) do
    conn
    |> get_req_header("referer")
    |> List.first()
    |> case do
      nil ->
        ~p"/"

      referer ->
        case URI.parse(referer).path do
          nil -> ~p"/"
          path -> path
        end
    end
  end
end
