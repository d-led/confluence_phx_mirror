defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderer do
  @moduledoc """
  What it takes to teach the mirror a macro: one module per `data-macro` name.

  A renderer answers a marker with ordinary HTML nodes, and everything it may
  work from is in the `Context` — the page the marker sits on, that page's own
  headings, and the content port. Nothing is loaded from outside the source
  tree and nothing is looked up by name at runtime, so a macro is a small
  function with a test, not a plugin host:

      defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Children do
        @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

        alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

        @impl true
        def render(_attrs, %Context{} = context) do
          pages = context.source.children(context.page, context.page, limit: 50)

          case pages do
            [] -> [Nodes.empty("This page has no child pages.")]
            pages -> [Nodes.heading("Child pages"), Nodes.page_list(pages)]
          end
        end
      end

  Then one line in `Registry` and every page carrying
  `<div class="mirror-macro" data-macro="children"></div>` gets the answer at its
  next expansion. See `docs/developers.md` for the walk-through.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.Context

  @typedoc """
  The marker's `data-*` attributes without the prefix: `data-labels` arrives as
  `"labels"`, so a renderer never parses HTML. Attributes the macro does not know
  are simply absent.
  """
  @type attrs :: %{optional(String.t()) => String.t()}

  @typedoc "Floki nodes, which the expander serialises into the page body."
  @type nodes :: [Floki.html_node()]

  @doc """
  The HTML that replaces the marker's contents.

  Always answer with something a reader can use: a macro with nothing to show
  renders a notice (`Nodes.empty/1`), never an empty list — a marker that
  silently disappears is a rendering bug an operator cannot see.
  """
  @callback render(attrs(), Context.t()) :: nodes()

  @doc "Whether `module` can draw a macro, which is what `Registry` promises."
  @spec implements?(module()) :: boolean()
  def implements?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :render, 2)
  end

  @doc "The macro names `module` draws, as the expander sees them."
  @spec macros(module()) :: [String.t()]
  def macros(module) do
    for {name, renderer} <- ConfluencePhxMirror.Sync.DynamicContent.Registry.all(),
        renderer == module,
        do: name
  end
end
