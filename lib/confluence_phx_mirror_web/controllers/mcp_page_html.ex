defmodule ConfluencePhxMirrorWeb.McpPageHTML do
  @moduledoc false

  use ConfluencePhxMirrorWeb, :html

  embed_templates "mcp_page_html/*"

  attr :number, :string, required: true
  attr :title, :string, required: true
  attr :summary, :string, required: true
  slot :inner_block, required: true

  @doc "One way in: a numbered card with the settings it needs under it."
  def option(assigns) do
    ~H"""
    <section
      id={"mcp-option-#{@number}"}
      class="rounded-xl border border-base-300 bg-base-100 p-4 shadow-sm"
    >
      <div class="flex items-start gap-3">
        <span class="grid size-7 shrink-0 place-items-center rounded-full bg-primary/10 text-xs font-semibold text-primary">
          {@number}
        </span>
        <div class="min-w-0">
          <h2 class="text-base font-semibold">{@title}</h2>
          <p class="mt-0.5 text-sm text-base-content/70">{@summary}</p>
        </div>
      </div>
      <div class="mt-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end
end
