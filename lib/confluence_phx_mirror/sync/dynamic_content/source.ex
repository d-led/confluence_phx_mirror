defmodule ConfluencePhxMirror.Sync.DynamicContent.Source do
  @moduledoc """
  What a macro may resolve from — and the one place the audience rule lives.

  Confluence resolves a macro per viewer. A mirror resolves it once, at sync
  time, and bakes one answer into the page for everybody, so everything a macro
  lists must be at least as wide as the page that lists it: whoever may read the
  host may read what it names (`ConfluencePhxMirror.Authorization.readable_alongside/2`).

  Keeping that rule in the adapter rather than in each renderer is the point of
  this module. A renderer cannot forget it, and a new macro inherits it by
  calling one of these functions.

  `ConfluencePhxMirror.Sync.DynamicContent.Source.Mirror` is the implementation
  the mirror ships; a test passes a double in the `Context` instead.
  """

  alias ConfluencePhxMirror.Mirror.Page

  @doc """
  Pages carrying the labels, newest first.

  Options: `:match` — `:all` (default) or `:any`; `:limit`; `:space` — a space
  key to narrow to, absent for "any space this page's readers may see".
  """
  @callback pages_by_label(host :: Page.t(), [String.t()], keyword()) :: [Page.t()]

  @doc """
  A space's page-properties report: its columns and one row per page carrying
  properties. `space` is a key, or nil for the host page's own space.
  """
  @callback property_report(host :: Page.t(), space :: String.t() | nil, [String.t()]) ::
              %{columns: [String.t()], rows: [%{page: Page.t(), values: map()}]}

  @doc """
  The pages directly below `page`, by title.

  Options: `:limit`. The host decides the audience: a child the host's readers
  may not open is not listed.
  """
  @callback children(host :: Page.t(), page :: Page.t(), keyword()) :: [Page.t()]
end
