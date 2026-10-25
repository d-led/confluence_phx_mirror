defmodule ConfluencePhxMirror.PageUpdates do
  @moduledoc """
  "This page was written again" — for the tab that is reading it.

  A page view is a controller response: it has no process of its own, so nothing
  in it can notice that a sync has replaced the page under the reader. The page
  carries a small LiveView instead, which subscribes here; a sync that finishes
  a page says so, and the reader is *offered* a reload instead of having the
  screen change mid-sentence.

  The message carries when the mirror read the page (`synced_at`, ISO 8601), so
  a tab that already shows that copy can ignore it: opening a page in the middle
  of a run must not prompt for a reload of what it has just been given. Both
  sides are fixed-width UTC strings, so they compare as strings.
  """

  @prefix "page-updates:"

  @doc "The topic the readers of one page watch."
  @spec topic(integer()) :: String.t()
  def topic(page_id), do: @prefix <> to_string(page_id)

  @doc "Subscribes the calling process to the writes of one page."
  def subscribe(page_id), do: Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, topic(page_id))

  @doc """
  Says that this page has been written, and when the mirror read it.

  Called once per page a sync finishes, after its transaction has committed:
  what a reader would reload is on disk by then.
  """
  @spec page_synced(%{id: integer(), synced_at: DateTime.t() | nil}) :: :ok
  def page_synced(%{id: id, synced_at: synced_at}) do
    Phoenix.PubSub.broadcast(
      ConfluencePhxMirror.PubSub,
      topic(id),
      {:page_synced, id, at(synced_at)}
    )
  end

  defp at(nil), do: nil
  defp at(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
