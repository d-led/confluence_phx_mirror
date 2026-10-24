defmodule ConfluencePhxMirrorWeb.LiveUserAuth do
  @moduledoc """
  LiveView `on_mount` hooks for reader identity and admin access.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Scope, User}
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sites

  def on_mount(:default, _params, session, socket) do
    {:cont, attach_site_context(assign_scope(socket, session))}
  end

  @doc """
  Mounts a screen that belongs to one reader: no identity, no screen.

  Anonymous readers are sent to sign in rather than shown an empty page, and a
  disabled account counts as no identity here as it does everywhere else.
  """
  def on_mount(:signed_in, _params, session, socket) do
    socket = assign_scope(socket, session)

    if Scope.signed_in?(socket.assigns.current_scope) do
      {:cont, attach_site_context(socket)}
    else
      {:halt, socket |> put_flash(:error, "Please sign in.") |> redirect(to: "/session")}
    end
  end

  def on_mount(:admin, _params, session, socket) do
    socket = assign_scope(socket, session)

    if Scope.admin?(socket.assigns.current_scope) do
      {:cont, socket |> attach_site_context() |> recheck_authority()}
    else
      message =
        if Scope.signed_in?(socket.assigns.current_scope),
          do: "Administrator access required.",
          else: "Please sign in."

      target = if Scope.signed_in?(socket.assigns.current_scope), do: "/", else: "/session"

      {:halt, socket |> put_flash(:error, message) |> redirect(to: target)}
    end
  end

  # A LiveView rendered by the router is handed the request's assigns as
  # `assign_new` defaults, so the browser pipeline has already resolved the
  # identity and the site context. Only a websocket mount — which has no request
  # behind it — has to load them, and `assign_new` is where both flavours meet.
  defp assign_scope(socket, session) do
    socket = assign_new(socket, :current_user, fn -> reader(session) end)

    case socket.assigns do
      %{current_scope: %Scope{}} ->
        socket

      _unset ->
        assign(socket, :current_scope, Scope.for_user(socket.assigns.current_user))
    end
  end

  @doc """
  The user a LiveView session belongs to.

  Public because the presence widgets are rendered into pages the router never
  mounted, and they must recognize a reader exactly as the pages around them do.
  """
  def reader(session) do
    case session["user_id"] do
      nil ->
        if Application.get_env(:confluence_phx_mirror, :auto_admin, false),
          do: Accounts.ensure_admin!(),
          else: nil

      id ->
        id |> Accounts.get_user() |> active()
    end
  end

  # A disabled account is nobody, exactly as the request plugs treat it.
  defp active(%User{} = user), do: if(User.disabled?(user), do: nil, else: user)
  defp active(nil), do: nil

  defp attach_site_context(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign_new(:spaces, fn ->
      Authorization.readable_spaces(scope,
        limit: ConfluencePhxMirrorWeb.Plugs.SiteContext.switcher_limit()
      )
    end)
    |> assign_new(:last_sync_run, fn -> Mirror.last_successful_sync_run() end)
    |> assign_new(:mirror_name, fn -> Sites.name() end)
    |> assign_new(:mirror_url, fn -> Sites.url() end)
    |> assign_new(:mirror_host, fn -> Sites.host() end)
    |> assign_new(:mirror_source, fn -> ConfluencePhxMirror.Confluence.Source.source() end)
  end

  # Administration is a property of the account, not of the socket it opened. An
  # admin screen can stay open for hours, so every action re-reads who is asking:
  # an administrator who still is one carries on undisturbed, and one demoted or
  # deleted meanwhile loses the page on the next click instead of keeping it.
  defp recheck_authority(socket) do
    attach_hook(socket, :admin_authority, :handle_event, fn _event, _params, socket ->
      scope = refreshed_scope(socket)

      if Scope.admin?(scope) do
        {:cont, assign(socket, :current_scope, scope)}
      else
        {:halt,
         socket
         |> put_flash(:error, "Administrator access required.")
         |> redirect(to: "/")}
      end
    end)
  end

  defp refreshed_scope(socket) do
    %{id: id} = socket.assigns.current_user
    Scope.for_user(Accounts.get_user(id))
  end
end
