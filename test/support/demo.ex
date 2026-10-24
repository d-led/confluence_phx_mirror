defmodule ConfluencePhxMirror.Demo do
  @moduledoc """
  The facts the bundled demo snapshot encodes, named.

  Tests about permissions read much better when they say *which* page they mean
  rather than quoting an identifier, and a single place to look when the demo
  content changes.
  """

  alias ConfluencePhxMirror.Mirror.Page

  # "Architecture Overview" — no restriction at all, on purpose.
  @open_page "1002"
  @open_page_title "Architecture Overview"

  # "Macros Gallery" — restricted to the group below, so it is the page every
  # access test can use as "something this reader may not open".
  @restricted_page "1003"
  @restricted_page_title "Macros Gallery"
  @page_readers "confluence-users"

  # "Getting Started" — the parent of the open page and of the restricted one, so
  # a child list and its count can be asserted to hold exactly the half a reader
  # may open.
  @open_page_parent "1001"
  @open_page_parent_title "Getting Started"

  # "Cross-links and Backlinks" — an open page that links to the restricted one,
  # so its outgoing rail has something to leave out.
  @crosslinks_page "1006"
  @crosslinks_page_title "Cross-links and Backlinks"

  # A label only the restricted page carries: nothing about it may show up in a
  # catalogue a reader outside the group browses.
  @restricted_page_label "macros"

  # A label the restricted page shares with one open page, so a count can be
  # asserted to include exactly the half the reader may open.
  @shared_label "demo"

  # A diagram attached to the open page: the bytes exist, so a download can be
  # asserted end to end.
  @open_page_attachment "9001"
  @open_page_attachment_name "diagram.svg"

  # A CSV on the same page, for the "force a download" case.
  @open_page_csv "9002"
  @open_page_csv_name "architecture.csv"

  @doc "A page every reader may open."
  def open_page, do: @open_page

  @doc "The same page as a number, for topic names and id comparisons."
  def open_page_number, do: String.to_integer(@open_page)

  # The slug is the pipeline's, not a constant here: Confluence's rule decides
  # what a page URL looks like, and a test should break when that rule changes
  # rather than quietly carrying a stale expectation.
  @doc "Slug of the open page, for its reader URL."
  def open_page_slug, do: Page.slugify(@open_page_title)

  @doc "Title of the open page, as the mirror renders it."
  def open_page_title, do: @open_page_title

  @doc "A page restricted to the readers in `page_readers/0`."
  def restricted_page, do: @restricted_page

  @doc "The same page as a number, for topic names and id comparisons."
  def restricted_page_number, do: String.to_integer(@restricted_page)

  @doc "Slug of the restricted page, for its reader URL."
  def restricted_page_slug, do: Page.slugify(@restricted_page_title)

  @doc "Title of the restricted page, as the mirror renders and exports it."
  def restricted_page_title, do: @restricted_page_title

  @doc "The group that may read the restricted page."
  def page_readers, do: @page_readers

  @doc "The page whose children are the open page and the restricted one."
  def open_page_parent, do: @open_page_parent

  @doc "Title of that parent, as the mirror renders it."
  def open_page_parent_title, do: @open_page_parent_title

  @doc "Slug of that parent, for its reader URL."
  def open_page_parent_slug, do: Page.slugify(@open_page_parent_title)

  @doc "The same page as a number, for topic names and id comparisons."
  def open_page_parent_number, do: String.to_integer(@open_page_parent)

  @doc "An open page that links to the restricted page."
  def crosslinks_page, do: @crosslinks_page

  @doc "Title of that page, as the mirror renders it."
  def crosslinks_page_title, do: @crosslinks_page_title

  @doc "Slug of that page, for its reader URL."
  def crosslinks_page_slug, do: Page.slugify(@crosslinks_page_title)

  @doc "A label only the restricted page carries."
  def restricted_page_label, do: @restricted_page_label

  @doc "A label the restricted page shares with one open page."
  def shared_label, do: @shared_label

  @doc "Attachment on the open page, with bytes behind it."
  def open_page_attachment, do: @open_page_attachment

  @doc "File name of that attachment."
  def open_page_attachment_name, do: @open_page_attachment_name

  @doc "CSV on the open page, for download-disposition cases."
  def open_page_csv, do: @open_page_csv

  @doc "File name of that CSV."
  def open_page_csv_name, do: @open_page_csv_name
end
