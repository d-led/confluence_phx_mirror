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

  @doc """
  Every page below `page`, transitively, in level order — the subtree a page tree
  draws.

  Options: `:limit`. Each returned page keeps its `parent_id`, which is what the
  tree is built from, and a descendant the host's readers may not open is left
  out.
  """
  @callback descendants(host :: Page.t(), page :: Page.t(), keyword()) :: [Page.t()]

  @doc """
  The page titled `title` in the host's space — or in the space `title` names as
  `KEY/Page Title`, the way Confluence writes a cross-space reference — when the
  host's readers may open it.

  One answer for two situations — there is no such page, or these readers may
  not know it exists — because a macro baked into a public page must not tell a
  stranger that a page of that name is there.
  """
  @callback page_by_title(host :: Page.t(), title :: String.t()) :: {:ok, Page.t()} | :error

  @doc """
  The pages that answer `cql`, in the order the query asks for — including its
  own `LIMIT`, because the query is the page author's, not the mirror's.

  A macro that lets a page author write a query asks this. An `{:error, reason}`
  is a question the mirror cannot answer — an unsupported field, a user-specific
  function, a typo — and the macro shows the reason instead of an empty list
  that would look like "nothing matched".

  Every page returned is one the host's readers may open.
  """
  @callback search(host :: Page.t(), cql :: String.t()) ::
              {:ok, [Page.t()]} | {:error, String.t()}

  @doc """
  The people whose names are on the pages of a space, most prolific first.

  Each row is `%{name:, account_id:, pages:}`, counted over the pages the host's
  readers may open — a person who wrote only inside a restricted part of the
  space is not named. `space` is a key, or nil for the host's own space; `:limit`
  caps how many people come back.

  A space larger than the port is willing to scan is `{:error, :too_large}`
  rather than a partial count: "wrote 12 pages" is a statement, and half a
  statement is not one.
  """
  @callback contributors(host :: Page.t(), space :: String.t() | nil, keyword()) ::
              {:ok, [%{name: String.t(), account_id: String.t() | nil, pages: pos_integer()}]}
              | {:error, :too_large}

  @doc """
  The files attached to `page`, by file name.

  An attachment is exactly as readable as the page holding it, so a macro that
  lists the host's own files needs no audience of its own.
  """
  @callback attachments(page :: Page.t()) :: [ConfluencePhxMirror.Mirror.Attachment.t()]
end
