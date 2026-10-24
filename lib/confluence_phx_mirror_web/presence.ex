defmodule ConfluencePhxMirrorWeb.Presence do
  @moduledoc """
  Presence for readers of the mirror.

  A content page has a topic of its own (`page:<confluence_id>`) that lists who
  is reading it. Every reader also joins the site topic (`site`), so the footer
  can say how many people have the mirror open.

  A reader is keyed by their account when signed in — two tabs are one person —
  and by their connection otherwise, since nothing else tells anonymous readers
  apart.

  The readers are tracked by the two LiveViews rendered into the pages
  (`PagePresenceLive`, `SitePresenceLive`): the pages themselves are controller
  responses, and a LiveView is the process that lives exactly as long as the
  reader has the page open.
  """

  use Phoenix.Presence,
    otp_app: :confluence_phx_mirror,
    pubsub_server: ConfluencePhxMirror.PubSub

  alias ConfluencePhxMirror.Accounts.User

  @site_topic "site"
  @anonymous "Anonymous reader"

  @doc "Topic used by a page's readers."
  def topic(confluence_id), do: "page:#{confluence_id}"

  @doc "The topic every reader joins, whatever they are looking at."
  def site_topic, do: @site_topic

  @doc "The key a reader is tracked under."
  def key(%User{id: id}), do: "user:#{id}"

  def key(nil),
    do: "reader:" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc "The name the other readers of a page see."
  def name(%User{display_name: nil, email: email}), do: email
  def name(%User{display_name: name}), do: name
  def name(nil), do: @anonymous

  @doc """
  Asks for a topic's changes, which arrive as `presence_diff` broadcasts.
  """
  def subscribe(topic), do: Phoenix.PubSub.subscribe(ConfluencePhxMirror.PubSub, topic)

  @doc "The names of the readers on a topic, one per person, in order."
  def readers(topic) do
    topic
    |> list()
    |> Enum.map(fn {_key, %{metas: [meta | _]}} -> meta[:user] end)
    |> Enum.sort()
  end

  @doc "Number of readers with the mirror open."
  def online_count, do: @site_topic |> list() |> map_size()

  @doc """
  The site topic's key for a reader.

  Derived from the reader's own key, so two tabs are still one person, but
  opaque: every client on the site receives this topic's state and the footer
  only needs the count — not a list of who is here or which accounts they are.
  """
  def site_key(reader_key), do: "reader:" <> digest(reader_key)

  # Salted with the deployment's secret: unsalted, anyone could hash candidate
  # account ids and read the state back as a list of who is online.
  defp digest(reader_key) do
    salt = ConfluencePhxMirrorWeb.Endpoint.config(:secret_key_base) || "site presence"

    :crypto.hash(:sha256, [reader_key, salt])
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 22)
  end
end
