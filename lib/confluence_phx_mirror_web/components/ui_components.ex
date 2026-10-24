defmodule ConfluencePhxMirrorWeb.UIComponents do
  @moduledoc """
  Small, composable function components used across the mirror.

  Slots carry the varying parts: `data_table` takes a `<:row :let={row}>`
  template and renders it per row, `card` and `section` take `<:actions>`, and
  `page_header` takes `<:meta>` and `<:actions>`.
  """

  use ConfluencePhxMirrorWeb, :html

  @doc "A bordered card with an optional title and action slot."
  attr :title, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class={["rounded-xl border border-base-300/70 bg-base-100", @class]}>
      <header
        :if={@title || @actions != []}
        class="flex items-center justify-between gap-2 border-b border-base-300/60 px-4 py-2.5"
      >
        <h2
          :if={@title}
          class="flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/70"
        >
          <.icon :if={@icon} name={@icon} class="size-3.5" /> {@title}
        </h2>
        <div class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      <div class="p-4">{render_slot(@inner_block)}</div>
    </section>
    """
  end

  @doc """
  One metric in a strip: icon, label, value.

  Metrics belong on one line, not in four boxes: an operator reads them
  together, and a tile per number is a frame drawn around a word. The strip
  wraps between items on a narrow screen, never inside one.
  """
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, default: nil
  slot :hint, doc: "a quieter trailing detail, such as when the number was measured"

  def stat(assigns) do
    ~H"""
    <span class="flex min-w-0 items-baseline gap-1.5 whitespace-nowrap">
      <.icon :if={@icon} name={@icon} class="size-4 shrink-0 self-center opacity-50" />
      <span class="text-[11px] uppercase tracking-wider text-base-content/70">{@label}</span>
      <span class="font-semibold tabular-nums">{@value}</span>
      <%!-- The trailing detail is the first thing to go when the strip is two
      columns wide. --%>
      <span :if={@hint != []} class="hidden text-[11px] text-base-content/60 sm:inline">
        {render_slot(@hint)}
      </span>
    </span>
    """
  end

  @doc "A titled region with an action slot and an optional metadata line."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :any, default: "mt-6"
  slot :actions
  slot :meta
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class={@class}>
      <div class="mb-3 flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/70">
            {@title}
          </h2>
          <p :if={@subtitle} class="mt-1 text-xs text-base-content/70">{@subtitle}</p>
          <div
            :if={@meta != []}
            class="mt-1 flex flex-wrap items-center gap-2 text-[11px] text-base-content/70"
          >
            {render_slot(@meta)}
          </div>
        </div>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  A table whose rows are a slot template:

      <.data_table id="runs" rows={@runs}>
        <:head><th>Started</th></:head>
        <:row :let={run}><td>{run.mode}</td></:row>
        <:empty>No runs.</:empty>
      </.data_table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  slot :head, doc: "one `<th>` per column, used from `sm` up"

  slot :row,
    required: true,
    doc: "one `<tr>` per row, used from `sm` up"

  slot :card,
    doc: """
    the same row as a phone card. A table on a phone is a desktop layout in a
    narrower box: the columns that survive are the ones nobody needs, and the
    ones that matter are hidden. Give `:card` and the phone gets a stacked
    record instead, with each value labelled.
    """

  slot :empty

  def data_table(assigns) do
    # A table without a phone card is a table with no `<:card>` slot at all.
    assigns = assign_new(assigns, :card, fn -> [] end)

    ~H"""
    <div :if={@card != []} class="-mx-4 sm:hidden">
      <ul class="divide-y divide-base-300/60">
        <li :for={row <- @rows} class="px-4 py-3">{render_slot(@card, row)}</li>
        <li :if={@rows == []} class="px-4 py-6 text-center text-xs text-base-content/70">
          {render_slot(@empty)}
        </li>
      </ul>
    </div>
    <div class={[
      "overflow-x-auto rounded-xl border border-base-300/70 bg-base-100",
      @card != [] && "hidden sm:block"
    ]}>
      <table id={@id} class="table table-sm">
        <thead>
          <tr>{render_slot(@head)}</tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} id={row_id(row)} class="hover:bg-base-200/40">
            {render_slot(@row, row)}
          </tr>
          <tr :if={@rows == []}>
            <td colspan="99" class="py-8 text-center text-xs text-base-content/70">
              {render_slot(@empty)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # A row may name itself (`:dom_id`), which is what lets a test or a hook
  # address one line of the table.
  defp row_id(row) when is_map(row), do: row[:dom_id]
  defp row_id(_row), do: nil

  @typedoc """
  One line of a searchable select: the value a choice carries, the words that
  name it, and an optional short badge (`ENG`, a count) beside them.
  """
  @type option :: %{value: String.t(), label: String.t(), badge: String.t() | nil}

  @doc """
  A find box over a short list: type to narrow, arrow keys to walk the matches,
  Enter to take the highlighted one.

  The list is the server's, because "what matches" is the server's question —
  the admin dashboard narrows spaces in the database, the search screen over
  the spaces it already holds. Only the highlight is the browser's, so walking
  a list costs no round trip per keystroke, and Enter is a click on the
  highlighted line: the caller hears the same event a mouse would send.
  """
  attr :id, :string, required: true, doc: "the widget's DOM id; its parts are named from it"
  attr :name, :string, required: true, doc: "the input's name, and so the form's payload key"
  attr :query, :string, required: true
  attr :options, :list, required: true, doc: "`option/0` maps, badges included as nil"
  attr :placeholder, :string, default: "Find one"
  attr :empty, :string, default: "Nothing matches"
  attr :change_event, :string, required: true, doc: "narrowing as the reader types"
  attr :submit_event, :string, required: true, doc: "Enter with nothing highlighted"
  attr :select_event, :string, required: true, doc: "taking an option, by click or by Enter"
  attr :value_param, :string, required: true, doc: "the `phx-value-*` a taken option carries"
  attr :pending, :string, default: nil, doc: "what an option says while its answer is on the way"

  def searchable_select(assigns) do
    ~H"""
    <div id={@id} phx-hook=".SelectKeys" class="space-y-1">
      <form id={"#{@id}-form"} phx-change={@change_event} phx-submit={@submit_event}>
        <input
          type="text"
          name={@name}
          value={@query}
          placeholder={@placeholder}
          autocomplete="off"
          role="combobox"
          aria-expanded="true"
          aria-controls={"#{@id}-options"}
          aria-autocomplete="list"
          phx-debounce="150"
          phx-mounted={JS.focus()}
          class="input input-sm w-full"
        />
      </form>

      <ul
        id={"#{@id}-options"}
        role="listbox"
        aria-label={@placeholder}
        class="menu menu-sm max-h-64 w-full flex-nowrap overflow-y-auto p-0"
      >
        <li :for={option <- @options} role="presentation">
          <button
            type="button"
            id={"#{@id}-option-#{option.value}"}
            role="option"
            aria-selected="false"
            phx-click={@select_event}
            phx-disable-with={@pending}
            {chosen_value(option.value, @value_param)}
          >
            <span class="truncate">{option.label}</span>
            <span :if={option.badge} class="badge badge-ghost badge-xs">{option.badge}</span>
          </button>
        </li>
        <li :if={@options == []} role="presentation">
          <button type="button" disabled>{@empty}</button>
        </li>
      </ul>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SelectKeys">
        export default {
          mounted() {
            this.cursor = -1
            // Typing asks the server for a new list, so a highlight from the
            // old one would name a different space by the time it arrives.
            this.input().addEventListener("input", () => this.paint(-1))
            this.el.addEventListener("keydown", event => this.key(event))
          },
          updated() {
            // The list can shrink under a highlight — a dashboard refresh
            // re-reads it every few seconds — so a cursor past the end goes
            // rather than staying on a line that is no longer there.
            this.paint(Math.min(this.cursor, this.options().length - 1))
          },
          key(event) {
            if (event.key === "ArrowDown" || event.key === "ArrowUp") {
              event.preventDefault()
              this.move(event.key === "ArrowDown" ? 1 : -1)
            }
            if (event.key === "Enter" && this.cursor >= 0) {
              // Enter takes the highlighted line; it does not submit the form.
              event.preventDefault()
              this.options()[this.cursor].click()
            }
          },
          // Walking off either end wraps around: a list of six has no far side
          // to bump into, and the first match is one key away from the last.
          move(delta) {
            const count = this.options().length
            if (count === 0) return
            if (this.cursor === -1) return this.paint(delta > 0 ? 0 : count - 1)
            this.paint((this.cursor + delta + count) % count)
          },
          paint(index) {
            this.cursor = index
            const options = this.options()
            options.forEach((option, position) => {
              const chosen = position === index
              option.setAttribute("aria-selected", String(chosen))
              option.classList.toggle("menu-active", chosen)
              if (chosen) option.scrollIntoView({block: "nearest"})
            })
            const highlighted = options[index]
            if (highlighted) this.input().setAttribute("aria-activedescendant", highlighted.id)
            else this.input().removeAttribute("aria-activedescendant")
          },
          options() {
            return Array.from(this.el.querySelectorAll("[role=option]"))
          },
          input() {
            return this.el.querySelector("[role=combobox]")
          }
        }
      </script>
    </div>
    """
  end

  # The event a taken option carries names its own value: `phx-value-key` for a
  # space key, `phx-value-space` for the search screen's filter.
  defp chosen_value(value, param), do: %{"phx-value-#{param}" => to_string(value)}

  @doc "Page title, eyebrow and metadata/action slots."
  attr :title, :string, required: true
  attr :eyebrow, :string, default: nil
  attr :class, :any, default: nil
  slot :badges
  slot :meta
  slot :actions
  slot :inner_block

  def page_header(assigns) do
    ~H"""
    <header class={["border-b border-base-300/70 pb-3 sm:pb-4", @class]}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p :if={@eyebrow} class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">
            {@eyebrow}
          </p>
          <div :if={@badges != []} class="mt-1 flex flex-wrap items-center gap-1.5">
            {render_slot(@badges)}
          </div>
          <h1 class="mt-1 text-balance text-2xl font-semibold leading-tight sm:text-3xl">
            {@title}
          </h1>
          <div
            :if={@meta != []}
            class="mt-1.5 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/70"
          >
            {render_slot(@meta)}
          </div>
        </div>
        <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      {render_slot(@inner_block)}
    </header>
    """
  end
end
