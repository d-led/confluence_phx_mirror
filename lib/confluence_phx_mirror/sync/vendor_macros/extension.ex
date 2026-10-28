defmodule ConfluencePhxMirror.Sync.VendorMacros.Extension do
  @moduledoc """
  What it takes to draw a third-party macro the mirror has no app for.

  A vendor macro is a placeholder Confluence cannot render without its app: the
  page carries `<ac:structured-macro ac:name="aura-tab-group">` and the app's
  JavaScript draws the tabs. A static mirror cannot run the app, but most of
  these macros are *containers* — their meaning is the body they wrap and the
  parameters they carry — so an extension draws them as ordinary HTML instead of
  apologising for them.

  An extension sees only what the page itself carries: the macro's name, its
  `<ac:parameter>` values and its already-rewritten children. It needs nothing
  from the mirror, which is why it runs while the storage is being sanitised
  rather than through `Sync.DynamicContent` (a macro that must query the mirror
  is a `Renderer`, not an extension).
  """

  @typedoc """
  One macro, as the page wrote it.

    * `name` — the lowercased `ac:name`;
    * `parameters` — `<ac:parameter ac:name="...">value</ac:parameter>`, by name;
    * `body` — the children of `<ac:rich-text-body>`, already sanitised and
      rewritten, so an extension can hand them straight on.
  """
  @type macro :: %{
          name: String.t(),
          parameters: %{optional(String.t()) => String.t()},
          body: [Floki.html_node()]
        }

  @doc """
  The HTML that replaces the macro.

  Draw the body rather than dropping it: a reader came for the content, and an
  extension that understands the wrapper is the only thing between them and an
  apology.
  """
  @callback draw(macro()) :: [Floki.html_node()]
end
