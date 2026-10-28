defmodule ConfluencePhxMirror.Sync.DynamicContent.Context do
  @moduledoc """
  Everything a macro renderer may work from.

  Four things, no more:

    * `page` — the page the marker sits on. It decides the URL prefix, the
      heading list a table of contents shows, and whose audience a listed page
      must fit inside;
    * `space` — that page's space, for a macro that names no space of its own;
    * `headings` — what the page itself offers a table of contents, read from the
      body being expanded (the ids Confluence writes are anchors a reader can
      follow);
    * `source` — the content port, the only way a renderer reaches the mirror,
      already narrowed to what this page's readers may open.

  Two more say where the body came from, and only a macro that includes another
  page reads them: `depth` is how many includes deep this body already is, and
  `seen` the pages that produced it, the host page first. They are what stops a
  page that includes itself from expanding for ever.

  A test builds one without a database: `%{space: space, page: page, source:
  StubContent}` passed to `DynamicContent.expand/2` is enough.
  """

  alias ConfluencePhxMirror.Sync.DynamicContent.Source

  @enforce_keys [:space, :page]
  defstruct [:space, :page, headings: [], source: Source.Mirror, depth: 0, seen: []]

  @typedoc "One heading of the page, as a table of contents lists it."
  @type heading :: %{level: 1..6, id: String.t(), text: String.t()}

  @type t :: %__MODULE__{
          space: ConfluencePhxMirror.Mirror.Space.t() | map(),
          page: ConfluencePhxMirror.Mirror.Page.t() | map(),
          headings: [heading()],
          source: module(),
          depth: non_neg_integer(),
          seen: [integer()]
        }
end
