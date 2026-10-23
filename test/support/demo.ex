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
