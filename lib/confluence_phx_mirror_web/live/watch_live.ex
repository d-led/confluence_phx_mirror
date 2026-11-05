defmodule ConfluencePhxMirrorWeb.WatchLive do
  @moduledoc """
  The Watch control, in a process of its own so that pressing it does not take
  the reader away from what they were reading.

  A page and a space are controller responses: a plain form there is a POST and a
  redirect back, which throws away the scroll position, the open dialogs and the
  place in the text — for a button that adds one row to a table. This is rendered
  into those responses with `live_render/3`, the way Presence and the space
  switcher already are, and it answers the press where the press happened.

  What it will not do is flip the label and hope. The write goes through
  `Notifications.subscribe/4` first and is read back before the button changes
  its mind; the audit entry is the one the controller used to write; and a
  refusal leaves the button saying what is true, with a sentence about why.

  It is told what it may watch through the session — `"watch_page"`,
  `"watch_space"`, `"watch_space_key"` — and it re-checks the reader's access
  itself rather than trusting the page that rendered it, because a mounted
  LiveView outlives the render that started it.
  """

  use ConfluencePhxMirrorWeb, :live_view

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.{Audit, Authorization, Mirror, Notifications}
  alias ConfluencePhxMirror.Notifications.Subscription
  alias ConfluencePhxMirrorWeb.LiveUserAuth

  @impl true
  def mount(_params, session, socket) do
    reader = LiveUserAuth.reader(session)
    scope = Scope.for_user(reader)

    {:ok,
     socket
     |> assign(:reader, reader)
     |> assign(:page, readable_page(session["watch_page"], scope))
     |> assign(:space, readable_space(session["watch_space"], scope))
     |> assign(:space_key, session["watch_space_key"])
     |> assign_watching()}
  end

  @impl true
  def handle_event("toggle", %{"target" => "page"}, socket) do
    toggle(socket, "page", socket.assigns.page, socket.assigns.watching_page?)
  end

  def handle_event("toggle", %{"target" => "space"}, socket) do
    toggle(socket, "space", socket.assigns.space, socket.assigns.watching_space?)
  end

  # The two buttons are the only source of this event; anything else is a caller
  # that is not this page, and refusing it is cheaper than a clause error that
  # takes the island down with it.
  def handle_event("toggle", _params, socket) do
    {:noreply, put_flash(socket, :error, "That is not something you can watch.")}
  end

  defp toggle(socket, type, target, watching?) do
    result =
      cond do
        is_nil(socket.assigns.reader) -> {:error, "Please sign in to watch anything."}
        is_nil(target) -> {:error, "That is not something you can watch."}
        watching? -> unwatch(socket.assigns.reader, type, target)
        true -> watch(socket.assigns.reader, type, target)
      end

    socket = assign_watching(socket)

    case result do
      {:ok, message} -> {:noreply, put_flash(socket, :info, message)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Written, then read back: `on_conflict: :nothing` answers `{:ok, _}` for a row
  # that already exists, and a button that believed it would be lying about the
  # one thing it claims.
  defp watch(reader, type, target) do
    with {:ok, subscription} <- Notifications.subscribe(reader, type, target.id),
         true <- Notifications.subscribed?(reader, type, target.id) do
      Audit.log({:user, reader}, Subscription.audit_event_created(subscription, reader))
      {:ok, "You will get an e-mail when this #{type} changes."}
    else
      _ -> {:error, "Could not create the subscription."}
    end
  end

  defp unwatch(reader, type, target) do
    :ok = Notifications.unsubscribe(reader, type, target.id)

    if Notifications.subscribed?(reader, type, target.id) do
      {:error, "Could not remove the subscription."}
    else
      Audit.log({:user, reader}, Subscription.audit_event_deleted(reader, type, target.id))
      {:ok, "Subscription removed."}
    end
  end

  defp assign_watching(socket) do
    %{reader: reader, page: page, space: space} = socket.assigns
    watched = watched(reader, [{"page", page}, {"space", space}])

    socket
    |> assign(:watching_page?, watching?(watched, "page", page))
    |> assign(:watching_space?, watching?(watched, "space", space))
  end

  # Both answers in one query, and none at all for a reader who is not signed in
  # — the same question the page used to ask before it rendered. A target the
  # island was not given is not on the list at all.
  @spec watched(map() | nil, list()) :: [{String.t(), integer()}]
  defp watched(%{} = reader, targets),
    do: reader |> Notifications.watching(ids(targets)) |> MapSet.to_list()

  defp watched(_reader, _targets), do: []

  defp ids(targets), do: for({type, %{id: id}} <- targets, do: {type, id})

  defp watching?(watched, type, %{id: id}), do: {type, id} in watched
  defp watching?(_watched, _type, nil), do: false

  defp readable_page(nil, _scope), do: nil

  defp readable_page(id, scope) do
    with {id, ""} <- Integer.parse(to_string(id)),
         {:ok, page} <- Mirror.find_page_by_local_id(id),
         true <- Authorization.can_read_page?(scope, page) do
      page
    else
      _ -> nil
    end
  end

  defp readable_space(nil, _scope), do: nil

  defp readable_space(id, scope) do
    with {id, ""} <- Integer.parse(to_string(id)),
         {:ok, space} <- Mirror.find_space_by_id(id),
         true <- Authorization.can_read_space?(scope, space) do
      space
    else
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@page} class="space-y-1">
      <p id="watch-page-note" class="text-xs text-base-content/70">
        {if @watching_page?,
          do: "You get an e-mail when this page changes.",
          else: "Get an e-mail when this page changes."}
      </p>
      <button
        type="button"
        id="watch-page"
        phx-click="toggle"
        phx-value-target="page"
        class={[
          "btn btn-xs w-full",
          if(@watching_page?, do: "btn-outline", else: "btn-primary")
        ]}
      >
        {if @watching_page?, do: "Stop watching", else: "Watch this page"}
      </button>
    </div>

    <div :if={@page && @space} class="mt-3 border-t border-base-300/60 pt-2"></div>

    <div :if={@space} class={["space-y-1", @page && "mt-3"]}>
      <p :if={@watching_space?} id="watch-space-note" class="text-[11px] text-base-content/70">
        Watching the whole space.
      </p>
      <button
        type="button"
        id="watch-space"
        phx-click="toggle"
        phx-value-target="space"
        class={[
          "btn btn-xs w-full",
          if(@watching_space?, do: "btn-outline", else: "btn-ghost")
        ]}
      >
        {if @watching_space?,
          do: "Stop watching #{@space_key}",
          else: "Watch all of #{@space_key}"}
      </button>
    </div>
    """
  end
end
