defmodule ConfluencePhxMirrorWeb.Admin.SettingsLive do
  @moduledoc """
  The settings screen: what an administrator can change while the mirror runs,
  and what only the environment can.

  The editable half is `ConfluencePhxMirror.Settings`, declared once in
  `ConfluencePhxMirror.Settings.Catalogue` and rendered from it group by group:
  one readable list, in the order an operator usually needs things, one form per
  group, one transaction per save — either every field of the group was stored
  and audited or none was.

  A filter over the whole page answers "where is this?" for a screen that has
  grown past a glance: every word has to match, and it narrows the boot
  configuration below as well, because half the answer to "can I change this?"
  is "no, and here is the variable that does" (`...Admin.SettingsFilter`).

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
  alias ConfluencePhxMirror.SpaceDirectory
  alias ConfluencePhxMirrorWeb.Admin.{Config, KeyField, Paging, SettingsFilter, SettingsRefusal}
  alias ConfluencePhxMirrorWeb.Skins

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings")
     |> assign(space_draft: nil, space_suggestions: [])
     |> assign(q: "", words: [])}
  end

  # The filter is the address, so "where do I change X?" is a question a
  # colleague can be sent — and the back button returns to the question before.
  @impl true
  def handle_params(params, _uri, socket) do
    q = Paging.query(params)

    {:noreply, socket |> assign(q: q, words: SettingsFilter.words(q)) |> assign_settings()}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/settings?#{[q: q]}")}
  end

  @impl true
  def handle_event("suggest_spaces", %{"values" => values}, socket) do
    draft = Map.get(values, "sync.spaces", "")

    {:noreply, put_draft(socket, draft)}
  end

  # A picked space goes where the operator was typing. The field is the only
  # place this screen holds unsaved text, so the draft — not the stored value —
  # is what a completion rewrites, and the browser is told to show it.
  def handle_event("pick_space", %{"key" => key}, socket) do
    draft = KeyField.complete(socket.assigns.space_draft, key)

    {:noreply,
     socket
     |> assign(:space_draft, draft)
     |> put_draft_from_assigns()
     |> push_event("space_key_value", %{value: draft})}
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
      {:noreply,
       socket
       |> assign(:space_draft, nil)
       |> assign_settings()
       |> put_flash(:info, "#{title} saved.")}
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
             |> assign(:space_draft, nil)
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

      <div class="mt-4">
        <.list_filter
          id="settings-filter"
          query={@q}
          label="Filter the settings by name, key or variable"
          placeholder="Name, key or CM_ variable"
        />
        <p :if={@q != ""} id="settings-filter-count" class="mt-1.5 text-xs text-base-content/70">
          <span id="settings-shown">{@settings_shown}</span>
          of {@settings_total} settings · every word has to match
        </p>
      </div>

      <div class="mt-4 space-y-4">
        <form
          id="theme-form"
          phx-submit="save_theme"
          class={[
            "rounded-xl border border-base-300/70 bg-base-100 p-4",
            @theme_hidden? && "hidden"
          ]}
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
          class={[
            "rounded-xl border border-base-300/70 bg-base-100",
            group.hidden? && "hidden"
          ]}
        >
          <input type="hidden" name="group" value={group.key} />

          <fieldset class="p-4">
            <legend class="text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70">
              {group.title}
            </legend>
            <p class="mt-1 text-xs text-base-content/70">{group.help}</p>

            <%!-- One setting per row, in the catalogue's order: a screen read
            top to bottom, not a grid read in four directions. --%>
            <div class="mt-2 divide-y divide-base-300/60 border-t border-base-300/60">
              <.setting_field :for={field <- group.fields} field={field} />
            </div>
          </fieldset>

          <div class="flex flex-wrap items-center justify-between gap-2 border-t border-base-300/60 bg-base-200/30 px-4 py-2.5">
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
              Save {String.downcase(group.title)} settings
            </button>
          </div>
        </form>
      </div>

      <p
        :if={@q != "" and @settings_shown == 0 and @sections == []}
        id="settings-no-match"
        class="mt-4 text-xs"
      >
        Nothing on this page matches “{@q}” — not a setting an administrator may
        change, and not a variable the deployment fixes.
      </p>

      <h2
        :if={@sections != []}
        class="mt-8 text-[11px] font-semibold uppercase tracking-[0.14em] text-base-content/70"
      >
        Fixed by the environment
      </h2>
      <p :if={@sections != []} class="mt-1 max-w-2xl text-xs text-base-content/70">
        Read at boot: change the variable and restart. Each row names the one that sets it.
      </p>

      <div :if={@sections != []} class="mt-3 grid gap-x-10 gap-y-6 lg:grid-cols-2">
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
    words = socket.assigns[:words] || []
    groups = groups(socket.assigns[:space_draft], socket.assigns[:space_suggestions] || [], words)

    assign(socket,
      theme: Skins.theme(),
      themes: Skins.themes(),
      theme_hidden?: not theme_shown?(words),
      groups: groups,
      settings_shown: groups |> Enum.flat_map(& &1.fields) |> Enum.count(&visible?/1),
      settings_total: Enum.sum(Enum.map(groups, &length(&1.fields))),
      sections: Config.sections(socket.assigns.current_user) |> SettingsFilter.sections(words)
    )
  end

  defp visible?(%{hidden?: hidden?}), do: not hidden?

  defp groups(draft, suggestions, words) do
    Catalogue.groups(:settings)
    |> Enum.map(fn group ->
      Map.put(group, :fields, Enum.map(group.keys, &field(&1, draft, suggestions)))
    end)
    |> SettingsFilter.groups(words)
  end

  # The theme is one setting with its own control (radio cards, because a palette
  # is chosen by looking at it), so it answers the filter through its catalogue
  # entry rather than through a row.
  defp theme_shown?(words) do
    spec = Catalogue.fetch!("theme")

    SettingsFilter.visible?(Enum.join(["Theme", spec.label, spec.help, spec.env], "\n"), words)
  end

  defp field(key, draft, suggestions) do
    spec = Catalogue.fetch!(key)
    value = Settings.stored(key)

    %{
      key: key,
      label: spec.label,
      help: spec.help,
      env: spec.env,
      type: spec.type,
      value: value,
      secret?: Map.get(spec, :secret?, false),
      default: Settings.default(key)
    }
    |> with_completion(spec.type, draft, value, suggestions)
  end

  # Only a list of space keys is typed against the site's own listing; every
  # other field is a number or a checkbox the site has no opinion about.
  defp with_completion(field, :csv, draft, value, suggestions) do
    Map.merge(field, %{
      draft: draft || csv_value(value),
      suggestions: suggestions
    })
  end

  defp with_completion(field, _type, _draft, _value, _suggestions), do: field

  # The suggestion rows live in the group's field maps, so they reach the page
  # only when the groups are rebuilt — assigning the list alone would change
  # nothing a reader can see.
  defp put_draft(socket, draft) do
    socket
    |> assign(space_draft: draft)
    |> put_draft_from_assigns()
  end

  defp put_draft_from_assigns(socket) do
    socket
    |> assign(:space_suggestions, suggestions(socket.assigns.space_draft))
    |> assign_settings()
  end

  # What the operator is typing answers the suggestion list, and the list comes
  # from the cache `SpaceDirectory` keeps: typing costs no request.
  defp suggestions(draft) do
    with true <- KeyField.open?(draft),
         {:ok, spaces} <-
           SpaceDirectory.suggest(KeyField.pending(draft), excluding: KeyField.named(draft)) do
      spaces
    else
      _closed_or_unreachable -> []
    end
  end

  attr :field, :map, required: true

  # A secret is never printed back: the field says whether one is set, and a
  # blank one leaves the value in force alone — the only shape that lets an
  # administrator change a password without being handed the old one.
  defp setting_field(%{field: %{secret?: true}} = assigns) do
    ~H"""
    <div
      id={"setting-#{@field.key}"}
      class={[
        "flex flex-col gap-1 py-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-6",
        @field.hidden? && "hidden"
      ]}
    >
      <label class="min-w-0" for={"setting-#{@field.key}-input"}>
        <span class="block text-sm">{@field.label}</span>
        <span class="block text-xs text-base-content/70">{@field.help}</span>
        <span class="mt-0.5 block text-[11px] text-base-content/70">
          {if @field.value, do: "a value is stored", else: "nothing stored"} ·
          <code class="font-mono">{@field.env}</code>
        </span>
      </label>
      <input
        type="password"
        id={"setting-#{@field.key}-input"}
        name={"values[#{@field.key}]"}
        value=""
        autocomplete="new-password"
        placeholder={if @field.value, do: "unchanged", else: "not set"}
        class="input input-sm w-full max-w-xs"
      />
    </div>
    """
  end

  defp setting_field(%{field: %{type: :boolean}} = assigns) do
    ~H"""
    <div id={"setting-#{@field.key}"} class={["py-2.5", @field.hidden? && "hidden"]}>
      <%!-- The input sits inside the label, so the label must not also point at
      it with `for`: a click on the box would then be delivered twice — once to
      the box and once by the label — and land back where it started. --%>
      <label class="flex items-start justify-between gap-4">
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
          <span class="mt-0.5 block text-[11px] text-base-content/70">
            Deployment: {on_off(@field.default)} · <code class="font-mono">{@field.env}</code>
          </span>
        </span>
        <input
          type="checkbox"
          id={"setting-#{@field.key}-input"}
          name={"values[#{@field.key}]"}
          checked={@field.value == true}
          class="checkbox checkbox-sm mt-0.5"
        />
      </label>
    </div>
    """
  end

  defp setting_field(%{field: %{type: {:choice, choices}} = field} = assigns) do
    assigns = assign(assigns, :field, field) |> assign(:choices, choices)

    ~H"""
    <div
      id={"setting-#{@field.key}"}
      class={[
        "flex flex-col gap-1 py-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-6",
        @field.hidden? && "hidden"
      ]}
    >
      <label class="min-w-0" for={"setting-#{@field.key}-input"}>
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
        <span class="mt-0.5 block text-[11px] text-base-content/70">
          Deployment: {@field.default} · <code class="font-mono">{@field.env}</code>
        </span>
      </label>
      <select
        id={"setting-#{@field.key}-input"}
        name={"values[#{@field.key}]"}
        class="select select-sm w-full max-w-xs"
      >
        <option value="" selected={@field.value == nil}>
          Use the deployment's
        </option>
        <option
          :for={{value, text} <- @choices}
          value={value}
          selected={@field.value == value}
        >
          {text}
        </option>
      </select>
    </div>
    """
  end

  # A free-text setting: a hostname, an address, a name. `:string` has no other
  # shape on this screen — the theme, the one string setting before the mail
  # server, is chosen on its own cards.
  defp setting_field(%{field: %{type: :string}} = assigns) do
    ~H"""
    <div
      id={"setting-#{@field.key}"}
      class={[
        "flex flex-col gap-1 py-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-6",
        @field.hidden? && "hidden"
      ]}
    >
      <label class="min-w-0" for={"setting-#{@field.key}-input"}>
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
        <span class="mt-0.5 block text-[11px] text-base-content/70">
          Empty means the deployment's {describe_default(@field.default)} ·
          <code class="font-mono">{@field.env}</code>
        </span>
      </label>
      <input
        type="text"
        id={"setting-#{@field.key}-input"}
        name={"values[#{@field.key}]"}
        value={@field.value}
        placeholder={to_string(@field.default || "")}
        class="input input-sm w-full max-w-xs"
      />
    </div>
    """
  end

  defp setting_field(%{field: %{type: type}} = assigns)
       when type in [:pos_integer, :non_negative, :hour] do
    ~H"""
    <div
      id={"setting-#{@field.key}"}
      class={[
        "flex flex-col gap-1 py-2.5 sm:flex-row sm:items-center sm:justify-between sm:gap-6",
        @field.hidden? && "hidden"
      ]}
    >
      <label class="min-w-0" for={"setting-#{@field.key}-input"}>
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
        <span class="mt-0.5 block text-[11px] text-base-content/70">
          Empty means the deployment's {to_string(@field.default)} ·
          <code class="font-mono">{@field.env}</code>
        </span>
      </label>

      <div class="w-full sm:w-44 sm:shrink-0">
        <.input
          type="number"
          id={"setting-#{@field.key}-input"}
          name={"values[#{@field.key}]"}
          value={@field.value}
          placeholder={to_string(@field.default)}
          min={minimum(@field.type)}
          max={if(@field.type == :hour, do: 23, else: nil)}
          class="w-full input input-sm"
        />
      </div>
    </div>
    """
  end

  defp setting_field(%{field: %{type: :csv}} = assigns) do
    ~H"""
    <div id={"setting-#{@field.key}"} class={["py-2.5", @field.hidden? && "hidden"]}>
      <%!-- A plain input rather than `<.input>`: that component's global
      attribute list does not carry `phx-change`, and this field is the one the
      site has suggestions for. --%>
      <label class="block text-sm" for={"setting-#{@field.key}-input"}>
        {@field.label}
        <span :if={@field.value != nil} class="ml-1 text-[10px] uppercase tracking-wide text-primary">
          changed
        </span>
      </label>
      <p class="text-xs text-base-content/70">{@field.help}</p>

      <.space_key_input
        id={"setting-#{@field.key}-input"}
        name={"values[#{@field.key}]"}
        value={@field.draft}
        change="suggest_spaces"
        class="mt-1 w-full input input-sm"
      />

      <.space_suggestions
        id={"#{@field.key}-suggestions"}
        suggestions={@field.suggestions}
        label="Spaces Confluence lists"
      />

      <p class="mt-0.5 text-[11px] text-base-content/70">
        Empty adds nothing · <code class="font-mono">{@field.env}</code> names the floor
      </p>
    </div>
    """
  end

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"
  defp on_off(nil), do: "the deployment's value"

  defp describe_default(nil), do: "value"
  defp describe_default(value), do: to_string(value)

  # A count that may be zero says so in the field itself: an interval of 0 is how
  # an administrator switches a schedule off.
  defp minimum(:pos_integer), do: 1
  defp minimum(_type), do: 0

  # A list setting is edited as the comma-separated text it is stored as.
  defp csv_value(nil), do: ""
  defp csv_value(keys) when is_list(keys), do: Enum.join(keys, ", ")

  defp actor(socket), do: {:user, socket.assigns.current_user}

  # The theme is an attribute of `<html>`, which only a document request renders,
  # so the save reloads the page: the administrator sees the theme they just
  # chose on the screen they chose it from.
  defp saved_theme(theme) do
    "Theme set to #{theme.label}. Every reader now wears it and still chooses light, dark or system."
  end
end
