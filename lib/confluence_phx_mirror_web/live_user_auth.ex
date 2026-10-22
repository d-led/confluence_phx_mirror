defmodule ConfluencePhxMirrorWeb.LiveUserAuth do
  @moduledoc """
  LiveView `on_mount` hooks for reader identity and admin access.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sites

  def on_mount(:default, _params, session, socket) do
    {:cont, attach_site_context(assign_scope(socket, session))}
  end

  def on_mount(:admin, _params, session, socket) do
    socket = assign_scope(socket, session)

    if Scope.admin?(socket.assigns.current_scope) do
      {:cont, attach_site_context(socket)}
    else
      message =
        if Scope.signed_in?(socket.assigns.current_scope),
          do: "Administrator access required.",
          else: "Please sign in."

      target = if Scope.signed_in?(socket.assigns.current_scope), do: "/", else: "/session"

      {:halt, socket |> put_flash(:error, message) |> redirect(to: target)}
    end
  end

  defp assign_scope(socket, session) do
    user =
      case session["user_id"] do
        nil ->
          if Application.get_env(:confluence_phx_mirror, :auto_admin, false),
            do: Accounts.ensure_admin!(),
            else: nil

        id ->
          Accounts.get_user(id)
      end

    socket
    |> assign(:current_user, user)
    |> assign(:current_scope, Scope.for_user(user))
  end

  defp attach_site_context(socket) do
    assign(socket,
      spaces: Authorization.readable_spaces(socket.assigns.current_scope),
      last_sync_run: Mirror.last_successful_sync_run(),
      mirror_name: Sites.name(),
      mirror_url: Sites.url(),
      mirror_host: Sites.host(),
      mirror_source: ConfluencePhxMirror.Confluence.Source.source()
    )
  end
end
