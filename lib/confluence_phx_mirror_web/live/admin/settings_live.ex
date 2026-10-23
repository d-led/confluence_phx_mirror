defmodule ConfluencePhxMirrorWeb.Admin.SettingsLive do
  @moduledoc """
  The setup screen: the theme every reader wears, then the configuration the
  mirror booted with.

  The theme is the only editable thing here, and it is the administrator's
  choice — readers pick the variant (light, dark, system) in the header. The
  rest is what the environment fixed at boot, shown so an operator can see the
  effect of a change without reading config files.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirrorWeb.Admin.Config
  alias ConfluencePhxMirrorWeb.Skins

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Settings",
       theme: Skins.theme(),
       themes: Skins.themes(),
       sections: Config.sections(socket.assigns.current_user)
     )}
  end

  @impl true
  def handle_event("save_theme", %{"theme" => name}, socket) do
    if Skins.theme?(name) do
      Settings.put_theme(name, {:user, socket.assigns.current_user})

      {:noreply,
       socket
       |> put_flash(:info, saved_message(Skins.get_theme(name)))
       |> redirect(to: ~p"/admin/settings")}
    else
      {:noreply, put_flash(socket, :error, "No theme named #{inspect(name)}.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      mirror_host={@mirror_host}
      mirror_source={@mirror_source}
      page_title="Settings"
      sidebar?={false}
    >
      <.admin_header
        current={:settings}
        title="Settings"
        subtitle="The theme the whole site wears, and the configuration this mirror booted with."
      />

      <form
        id="theme-form"
        phx-submit="save_theme"
        class="mt-5 rounded-xl border border-base-300/70 bg-base-100 p-4"
      >
        <fieldset>
          <legend class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
            Theme
          </legend>
          <p class="mt-1 max-w-2xl text-xs text-base-content/70">
            Applies to every reader. Each reader still picks light, dark or system in the header, and
            <em>system</em>
            follows their OS.
          </p>

          <div class="mt-3 grid gap-2 sm:grid-cols-2">
            <label
              :for={theme <- @themes}
              class={[
                "flex cursor-pointer items-start gap-3 rounded-lg border p-3 text-sm transition",
                if(theme.name == @theme,
                  do: "border-primary bg-primary/5",
                  else: "border-base-300/70 hover:border-base-300"
                )
              ]}
            >
              <input
                type="radio"
                name="theme"
                value={theme.name}
                checked={theme.name == @theme}
                class="radio radio-sm mt-0.5"
              />
              <span class="min-w-0">
                <span class="block font-medium">{theme.label}</span>
                <span :if={theme.note != ""} class="block text-xs text-base-content/70">
                  {theme.note}
                </span>
              </span>
            </label>
          </div>
        </fieldset>

        <div class="mt-3 flex items-center justify-end gap-2">
          <button type="submit" class="btn btn-primary btn-sm">Save theme</button>
        </div>
      </form>

      <div class="mt-6 grid gap-x-10 gap-y-6 lg:grid-cols-2">
        <section :for={section <- @sections}>
          <h2 class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
            {section.title}
          </h2>
          <dl class="mt-1.5 divide-y divide-base-300/60 border-t border-base-300/60">
            <div :for={row <- section.rows} class="flex items-start justify-between gap-4 py-1.5">
              <dt class="shrink-0 pt-px text-xs text-base-content/70">{row.label}</dt>
              <dd class="flex min-w-0 flex-wrap items-baseline justify-end gap-x-2 gap-y-0.5 text-right">
                <span class="text-xs font-medium">{row.value}</span>
                <code :if={row.env} class="font-mono text-[10px] text-base-content/70">{row.env}</code>
              </dd>
            </div>
          </dl>
        </section>
      </div>
    </Layouts.app>
    """
  end

  # The theme is an attribute of `<html>`, which only a document request renders,
  # so the save reloads the page: the administrator sees the theme they just
  # chose on the screen they chose it from.
  defp saved_message(theme) do
    "Theme set to #{theme.label}. Every reader now wears it and still chooses light, dark or system."
  end
end
