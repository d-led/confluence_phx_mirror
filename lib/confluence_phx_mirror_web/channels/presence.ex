defmodule ConfluencePhxMirrorWeb.Presence do
  @moduledoc """
  Presence for readers of a mirrored page.

  Tracking is per page topic (`page:<confluence_id>`); the page view renders the
  initial count server-side and then stays live over a channel, which is the
  canonical Phoenix Presence setup.
  """

  use Phoenix.Presence,
    otp_app: :confluence_phx_mirror,
    pubsub_server: ConfluencePhxMirror.PubSub

  @doc "Topic used by the page channel and the presence widget."
  def topic(confluence_id), do: "page:#{confluence_id}"

  @doc "Number of readers currently on the page."
  def count(confluence_id) do
    confluence_id
    |> topic()
    |> list()
    |> Enum.reduce(0, fn {_key, %{metas: metas}}, acc -> acc + length(metas) end)
  end
end
