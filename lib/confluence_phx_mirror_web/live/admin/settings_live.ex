defmodule ConfluencePhxMirrorWeb.Admin.SettingsLive do
  @moduledoc """
  The settings screen: what an administrator can change while the mirror runs,
  and what only the environment can.

  The editable half is `ConfluencePhxMirror.Settings` — the theme every reader
  wears, the per-reader request limits, and whether notification mail goes out.
  A field left blank means "no decision": the deployment's own configuration
  applies again, which is what the placeholder shows. Saving a group is one
  transaction, so either every field of it was stored and audited or none was.

  The other half is the environment the mirror booted with, listed with the
  variable that sets it. The source, the sync schedule and the database cannot
  be swapped under a running node, and a screen that pretended otherwise would
  be lying.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirrorWeb.Admin.Config
  alias ConfluencePhxMirrorWeb.Admin.SettingsRefusal
  alias ConfluencePhxMirrorWeb.Skins

  @limit_keys %{
    "html" => "reader.html_limit",
    "api" => "reader.api_limit",
    "attachments" => "reader.attachments_limit"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Settings") |> assign_settings()}
  end

  @impl true
  def handle_event("save_theme", %{"theme" => name}, socket) do
    if Skins.theme?(name) do
      {:ok, _applied} = Settings.put_theme(name, actor(socket))

      # The theme is an attribute of `<html>`, which only a document request
      # renders: reload so the administrator sees the theme they just chose.
      {:noreply,
       socket
       |> put_flash(:info, saved_theme(Skins.get_theme(name)))
       |> redirect(to: ~p"/admin/settings")}
    else
      {:noreply, put_flash(socket, :error, "No theme named #{inspect(name)}.")}
    end
  end

  def handle_event("save_limits", %{"limits" => params}, socket) do
    changes = Map.new(@limit_keys, fn {field, key} -> {key, params[field]} end)

    save(socket, changes, "Reader limits saved.")
  end

  def handle_event("save_notifications", %{"notifications" => params}, socket) do
    changes = %{
      "notifications.enabled" => truthy?(params["enabled"]),
      "notifications.digest_hour_utc" => params["digest_hour"]
    }

    save(socket, changes, "Notification settings saved.")
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
        subtitle="What you can change while the mirror runs, then what only the environment can."
      />

      <div class="mt-5 grid gap-4 lg:grid-cols-2">
        <form
          id="theme-form"
          phx-submit="save_theme"
          class="rounded-xl border border-base-300/70 bg-base-100 p-4 lg:col-span-2"
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

        <form
          id="limits-form"
          phx-submit="save_limits"
          class="rounded-xl border border-base-300/70 bg-base-100 p-4"
        >
          <fieldset>
            <legend class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
              Reader limits
            </legend>
            <p class="mt-1 text-xs text-base-content/70">
              Requests per reader per minute. Empty means the value this deployment was configured
              with; the placeholder is that value.
            </p>

            <div class="mt-3 grid gap-2 sm:grid-cols-3">
              <.input
                type="number"
                name="limits[html]"
                value={@limits.html}
                label="HTML"
                placeholder={to_string(@limits.defaults.html)}
                min="1"
                class="w-full input input-sm"
              />
              <.input
                type="number"
                name="limits[api]"
                value={@limits.api}
                label="API"
                placeholder={to_string(@limits.defaults.api)}
                min="1"
                class="w-full input input-sm"
              />
              <.input
                type="number"
                name="limits[attachments]"
                value={@limits.attachments}
                label="Attachments"
                placeholder={to_string(@limits.defaults.attachments)}
                min="1"
                class="w-full input input-sm"
              />
            </div>
          </fieldset>

          <div class="mt-3 flex items-center justify-end">
            <button type="submit" class="btn btn-primary btn-sm">Save limits</button>
          </div>
        </form>

        <form
          id="notifications-form"
          phx-submit="save_notifications"
          class="rounded-xl border border-base-300/70 bg-base-100 p-4"
        >
          <fieldset>
            <legend class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
              Notifications
            </legend>
            <p class="mt-1 text-xs text-base-content/70">
              Whether the mirror mails watchers at all, and the UTC hour the daily digest goes out.
            </p>

            <div class="mt-3 grid items-end gap-2 sm:grid-cols-2">
              <.input
                type="checkbox"
                name="notifications[enabled]"
                label="Send e-mail"
                checked={@notifications.enabled}
              />
              <.input
                type="number"
                name="notifications[digest_hour]"
                value={@notifications.digest_hour}
                label="Digest hour (UTC)"
                placeholder={to_string(@notifications.default_hour)}
                min="0"
                max="23"
                class="w-full input input-sm"
              />
            </div>
          </fieldset>

          <div class="mt-3 flex items-center justify-end">
            <button type="submit" class="btn btn-primary btn-sm">Save notifications</button>
          </div>
        </form>
      </div>

      <h2 class="mt-8 text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
        Fixed by the environment
      </h2>
      <p class="mt-1 max-w-2xl text-xs text-base-content/70">
        Read at boot: change the variable and restart. Each row names the one that sets it.
      </p>

      <div class="mt-3 grid gap-x-10 gap-y-6 lg:grid-cols-2">
        <section :for={section <- @sections}>
          <h3 class="text-xs font-semibold">{section.title}</h3>
          <dl class="mt-1 divide-y divide-base-300/60 border-t border-base-300/60">
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

  defp save(socket, changes, message) do
    case Settings.update(changes, actor(socket)) do
      {:ok, _applied} ->
        {:noreply, socket |> assign_settings() |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, SettingsRefusal.message(reason))}
    end
  end

  defp assign_settings(socket) do
    assign(socket,
      theme: Skins.theme(),
      themes: Skins.themes(),
      limits: limits(),
      notifications: notifications(),
      sections: Config.sections(socket.assigns.current_user)
    )
  end

  defp limits do
    %{
      html: stored_field("reader.html_limit"),
      api: stored_field("reader.api_limit"),
      attachments: stored_field("reader.attachments_limit"),
      defaults: %{
        html: Settings.default("reader.html_limit"),
        api: Settings.default("reader.api_limit"),
        attachments: Settings.default("reader.attachments_limit")
      }
    }
  end

  defp notifications do
    %{
      enabled: Settings.notifications_enabled?(),
      digest_hour: stored_field("notifications.digest_hour_utc"),
      default_hour: Settings.default("notifications.digest_hour_utc")
    }
  end

  # Only a decision is shown in the field; what the deployment configured lives
  # in the placeholder, so an empty box keeps meaning "no decision".
  defp stored_field(key) do
    case Settings.stored(key) do
      nil -> ""
      value -> to_string(value)
    end
  end

  defp actor(socket), do: {:user, socket.assigns.current_user}

  # A checked box posts "on"; an unchecked one posts nothing at all.
  defp truthy?(value), do: value in ~w(on true 1 yes)

  # The theme is an attribute of `<html>`, which only a document request renders,
  # so the save reloads the page: the administrator sees the theme they just
  # chose on the screen they chose it from.
  defp saved_theme(theme) do
    "Theme set to #{theme.label}. Every reader now wears it and still chooses light, dark or system."
  end
end
