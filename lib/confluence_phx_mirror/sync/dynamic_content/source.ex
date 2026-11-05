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

  Options: `:limit` — how many rows to read (default 50). A space with a
  property on every page is the whole catalogue, and a macro listing all of it
  would say nothing a reader could scan.
  """
  @callback property_report(
              host :: Page.t(),
              space :: String.t() | nil,
              [String.t()],
              keyword()
            ) ::
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
  The document behind a whiteboard the page embeds, or why it could not be read.

  A board is a canvas Confluence paints itself, and the export view carries only
  an unknown-macro placeholder for it. Its *document* is readable all the same —
  over GraphQL, as `WHITEBOARD_DOC_FORMAT` — and holds a node per shape with its
  geometry, z-index and words. `url` is the address the page recorded, which
  names the board's id.

  An `{:error, reason}` is not an empty board: the caller shows an apology and a
  link rather than a box that pretends the board is blank.
  """
  @callback whiteboard(host :: Page.t(), url :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  The record behind a database the page embeds: at least its `title`.

  A database is a *live view*, and this is the one place the two embeds differ.
  A board is a document, so the mirror draws it. A database's rows belong to the
  service its own iframe talks to, and neither the content body (empty) nor the
  export view carries them; what is readable is the database's own record, which
  is enough to name it properly and link it, and not enough to draw a table.

  An `{:error, reason}` means the mirror will not claim a name it does not have.
  """
  @callback database(host :: Page.t(), url :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc """
  The files attached to `page`, by file name.

  An attachment is exactly as readable as the page holding it, so a macro that
  lists the host's own files needs no audience of its own.
  """
  @callback attachments(page :: Page.t()) :: [ConfluencePhxMirror.Mirror.Attachment.t()]

  @doc """
  The labels a space's pages carry, most used first, with how many pages each.

  A label's count is pages carrying it — the one number the mirror can state.
  Both the labels and their counts are taken over the pages readable alongside
  the host, so a label only a narrower page carries is not named here.

  `space` is a key, or nil for the host's own space; `:limit` caps how many
  labels come back. A space larger than the port is willing to scan is
  `{:error, :too_large}` rather than a count that quietly stopped halfway.
  """
  @callback labels(host :: Page.t(), space :: String.t() | nil, keyword()) ::
              {:ok, [%{name: String.t(), pages: pos_integer()}]} | {:error, :too_large}

  @doc """
  One person, by Confluence account id, with the pages of theirs readable
  alongside the host.

  The name comes from the bylines the mirror has read — there is no separate
  people directory to ask — so a person the site knows but whose pages are all
  out of these readers' reach is still answered, with an empty list; a person the
  mirror has never seen is `:error`, because a name it does not have is not a
  name it may invent.

  Options: `:limit` — pages to come back, newest first.
  """
  @callback authored(host :: Page.t(), account_id :: String.t(), keyword()) ::
              {:ok, %{name: String.t(), pages: [Page.t()]}} | :error
end
