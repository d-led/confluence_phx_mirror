defmodule ConfluencePhxMirrorWeb.Presence do
  @moduledoc """
  Presence for readers of the mirror.

  A content page has a topic of its own (`page:<confluence_id>`) that lists who
  is reading it. Every reader also joins the site topic (`site`), so the footer
  can say how many people have the mirror open.

  A reader is identified by their account when signed in and by their socket
  otherwise, so one person with two tabs open is one reader.
  """

  use Phoenix.Presence,
    otp_app: :confluence_phx_mirror,
    pubsub_server: ConfluencePhxMirror.PubSub

  @site_topic "site"

  @doc "Topic used by the page channel and the presence widget."
  def topic(confluence_id), do: "page:#{confluence_id}"

  @doc "The topic every reader joins, whatever they are looking at."
  def site_topic, do: @site_topic

  @doc "Number of readers on a page."
  def count(confluence_id), do: confluence_id |> topic() |> reader_count()

  @doc "Number of readers with the mirror open."
  def online_count, do: @site_topic |> reader_count()

  @doc """
  The key a reader is tracked under: their account, or their socket when they
  are anonymous.
  """
  def reader_key(socket) do
    case socket.assigns[:user_id] do
      nil -> socket.id
      user_id -> "user:#{user_id}"
    end
  end

  # Presence keeps one entry per key with one meta per tab; a count asks how
  # many people, so it counts the entries, not the metas.
  defp reader_count(topic), do: topic |> list() |> map_size()
end
