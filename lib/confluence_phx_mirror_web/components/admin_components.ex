defmodule ConfluencePhxMirrorWeb.AdminComponents do
  @moduledoc """
  The admin area's chrome: one compact header and the section tabs, so the
  admin screens read as parts of one place instead of six.

  The split follows what each page is for: Overview and Webhooks are live,
  Sync log and Audit stream, Users are editable, and Settings is a static read
  of the configuration the mirror booted with.
  """

  use ConfluencePhxMirrorWeb, :html

  @tabs [
    {:overview, "Overview", "hero-squares-2x2"},
    {:sync_log, "Sync log", "hero-bars-arrow-down"},
    {:webhooks, "Webhooks", "hero-bolt"},
    {:audit, "Audit", "hero-clipboard-document-list"},
    {:users, "Users", "hero-users"},
    {:settings, "Settings", "hero-cog-6-tooth"}
  ]

  @doc """
  The admin page header: title, one line of context, the page's actions and the
  tabs to the other admin sections.
  """
  attr :current, :atom, required: true, values: Enum.map(@tabs, &elem(&1, 0))
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  slot :actions

  def admin_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-end justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-xl font-semibold leading-tight">{@title}</h1>
        <p :if={@subtitle} class="mt-0.5 text-xs text-base-content/70">{@subtitle}</p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>

    <nav
      class="mt-3 -mb-px flex gap-1 overflow-x-auto border-b border-base-300/70"
      aria-label="Administration"
    >
      <.link
        :for={{key, label, icon} <- tabs()}
        navigate={tab_path(key)}
        class={[
          "inline-flex shrink-0 items-center gap-1.5 border-b-2 px-2.5 py-2 text-xs font-medium transition",
          if(@current == key,
            do: "border-primary text-primary",
            else:
              "border-transparent text-base-content/70 hover:border-base-300 hover:text-base-content"
          )
        ]}
        aria-current={@current == key && "page"}
      >
        <.icon name={icon} class="size-3.5 shrink-0" /> {label}
      </.link>
    </nav>
    """
  end

  defp tabs, do: @tabs

  defp tab_path(:overview), do: ~p"/admin"
  defp tab_path(:sync_log), do: ~p"/admin/sync-log"
  defp tab_path(:webhooks), do: ~p"/admin/webhooks"
  defp tab_path(:audit), do: ~p"/admin/audit"
  defp tab_path(:trash), do: ~p"/admin/trash"
  defp tab_path(:users), do: ~p"/admin/users"
  defp tab_path(:settings), do: ~p"/admin/settings"
end
