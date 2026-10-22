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

  @doc "A single metric."
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :icon, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300/70 bg-base-100 p-4">
      <p class="flex items-center gap-1.5 text-[11px] uppercase tracking-wider text-base-content/70">
        <.icon :if={@icon} name={@icon} class="size-3.5" /> {@label}
      </p>
      <p class="mt-1 text-2xl font-semibold tabular-nums">{@value}</p>
      <p :if={@hint} class="mt-0.5 text-[11px] text-base-content/70">{@hint}</p>
    </div>
    """
  end

  @doc "A titled region with an action slot and an optional metadata line."
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :class, :any, default: "mt-8"
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
  slot :head
  slot :row, required: true
  slot :empty

  def data_table(assigns) do
    ~H"""
    <div class="overflow-x-auto rounded-xl border border-base-300/70 bg-base-100">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>{render_slot(@head)}</tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} class="hover:bg-base-200/40">{render_slot(@row, row)}</tr>
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
    <header class={["border-b border-base-300/70 pb-5", @class]}>
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <p :if={@eyebrow} class="text-[11px] font-semibold uppercase tracking-[0.18em] text-primary">
            {@eyebrow}
          </p>
          <div :if={@badges != []} class="mt-1 flex flex-wrap items-center gap-1.5">
            {render_slot(@badges)}
          </div>
          <h1 class="mt-1 text-balance text-3xl font-semibold leading-tight">{@title}</h1>
          <div
            :if={@meta != []}
            class="mt-1.5 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/60"
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
