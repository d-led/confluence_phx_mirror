defmodule ConfluencePhxMirrorWeb.Admin.SettingsLive do
  @moduledoc """
  The settings screen: what an administrator can change while the mirror runs,
  and what only the environment can.

  The editable half is `ConfluencePhxMirror.Settings`, declared once in
  `ConfluencePhxMirror.Settings.Catalogue` and rendered from it group by group.
  One form per group, one transaction per save: either every field of the group
  was stored and audited or none was.

  A blank field means "no decision" — the deployment's own configuration applies
  again, which is what the placeholder shows. A checkbox cannot be blank, so a
  group's *use the deployment's values* button is what hands it back.

  The other half is the environment the mirror booted with, listed with the
  variable that sets it. The source, the sync schedule and the database cannot
  be swapped under a running node, and a screen that pretended otherwise would
  be lying.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Settings.Catalogue
  alias ConfluencePhxMirrorWeb.Admin.Config
  alias ConfluencePhxMirrorWeb.Admin.SettingsRefusal
  alias ConfluencePhxMirrorWeb.Skins

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

  def handle_event("save_group", %{"group" => key} = params, socket) do
    values = Map.get(params, "values", %{})

    with %{title: title} = group <- group(key),
         changes = changes(group, values),
         {:ok, _applied} <- Settings.update(changes, actor(socket)) do
      {:noreply, socket |> assign_settings() |> put_flash(:info, "#{title} saved.")}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, SettingsRefusal.message(reason))}
    end
  end

  def handle_event("use_default", %{"group" => key}, socket) do
    case group(key) do
      nil ->
        {:noreply, socket}

      %{keys: keys, title: title} ->
        case Settings.clear(keys, actor(socket)) do
          {:ok, _cleared} ->
            {:noreply,
             socket
             |> assign_settings()
             |> put_flash(:info, "#{title} follows the deployment's configuration again.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, SettingsRefusal.message(reason))}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      live={@socket}
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      mirror_host={@mirror_host}
      mirror_source={@mirror_source}
      page_title="Settings"
      sidebar?={false}
    >
      <:subnav>
        <.admin_nav current={:settings} />
      </:subnav>

      <.admin_header
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
          :for={group <- @groups}
          id={"settings-#{group.key}"}
          phx-submit="save_group"
          class="rounded-xl border border-base-300/70 bg-base-100 p-4"
        >
          <input type="hidden" name="group" value={group.key} />

          <fieldset>
            <legend class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
              {group.title}
            </legend>
            <p class="mt-1 text-xs text-base-content/70">{group.help}</p>

            <div class="mt-3 space-y-4">
              <.setting_field :for={field <- group.fields} field={field} />
            </div>
          </fieldset>

          <div class="mt-4 flex flex-wrap items-center justify-between gap-2">
            <button
              type="button"
              id={"settings-#{group.key}-defaults"}
              phx-click="use_default"
              phx-value-group={group.key}
              class="btn btn-ghost btn-xs"
            >
              Use the deployment's values
            </button>
            <button type="submit" id={"settings-#{group.key}-save"} class="btn btn-primary btn-sm">
              Save {String.downcase(group.title)}
            </button>
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

  # The group a form names, or `nil` for a key this screen does not show.
  defp group(key) do
    Enum.find(Catalogue.groups(:settings), &(Atom.to_string(&1.key) == key))
  end

  # A checkbox posts nothing when it is cleared, which is an explicit "off":
  # handing a group back to the deployment is the button, not an empty box.
  defp changes(%{keys: keys}, values) do
    Map.new(keys, fn key ->
      case Catalogue.fetch!(key).type do
        :boolean -> {key, values[key] in ~w(on true 1 yes)}
        _typed -> {key, Map.get(values, key)}
      end
    end)
  end

  defp assign_settings(socket) do
    assign(socket,
      theme: Skins.theme(),
      themes: Skins.themes(),
      groups: groups(),
      sections: Config.sections(socket.assigns.current_user)
    )
  end

  defp groups do
    Enum.map(Catalogue.groups(:settings), fn group ->
      Map.put(group, :fields, Enum.map(group.keys, &field/1))
    end)
  end

  defp field(key) do
    spec = Catalogue.fetch!(key)

    %{
      key: key,
      label: spec.label,
      help: spec.help,
      env: spec.env,
      type: spec.type,
      value: Settings.stored(key),
      default: Settings.default(key)
    }
  end

  attr :field, :map, required: true

  defp setting_field(%{field: %{type: :boolean}} = assigns) do
    ~H"""
    <div>
      <label
        id={"setting-#{@field.key}"}
        for={"setting-#{@field.key}-input"}
        class="flex items-start justify-between gap-4"
      >
        <span class="min-w-0">
          <span class="block text-sm">
            {@field.label}
            <span
              :if={@field.value != nil}
              class="ml-1 text-[10px] uppercase tracking-wide text-primary"
            >
              changed
            </span>
          </span>
          <span class="block text-xs text-base-content/70">{@field.help}</span>
        </span>
        <input
          type="checkbox"
          id={"setting-#{@field.key}-input"}
          name={"values[#{@field.key}]"}
          checked={@field.value == true}
          class="checkbox checkbox-sm mt-0.5"
        />
      </label>
      <p class="mt-0.5 text-[11px] text-base-content/70">
        Deployment: {on_off(@field.default)} · <code class="font-mono">{@field.env}</code>
      </p>
    </div>
    """
  end

  defp setting_field(%{field: %{type: type}} = assigns) when type in [:pos_integer, :hour] do
    ~H"""
    <div id={"setting-#{@field.key}"}>
      <.input
        type="number"
        id={"setting-#{@field.key}-input"}
        name={"values[#{@field.key}]"}
        value={@field.value}
        label={@field.label}
        placeholder={to_string(@field.default)}
        min={if(@field.type == :hour, do: 0, else: 1)}
        max={if(@field.type == :hour, do: 23, else: nil)}
        class="mt-1 w-full input input-sm"
      />

      <p class="text-xs text-base-content/70">
        {@field.help}
        <span :if={@field.value != nil} class="ml-1 text-[10px] uppercase tracking-wide text-primary">
          changed
        </span>
      </p>

      <p class="mt-0.5 text-[11px] text-base-content/70">
        Empty means the deployment's {to_string(@field.default)} ·
        <code class="font-mono">{@field.env}</code>
      </p>
    </div>
    """
  end

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
  defp on_off(nil), do: "the deployment's value"

  defp actor(socket), do: {:user, socket.assigns.current_user}

  # The theme is an attribute of `<html>`, which only a document request renders,
  # so the save reloads the page: the administrator sees the theme they just
  # chose on the screen they chose it from.
  defp saved_theme(theme) do
    "Theme set to #{theme.label}. Every reader now wears it and still chooses light, dark or system."
  end
end
