defmodule ConfluencePhxMirrorWeb.Plugs.WebhookIntake do
  @moduledoc """
  Refuses every delivery while the intake is switched off.

  It refuses by raising what the router raises for a path nobody routed, so the
  answer is the endpoint's own 404 — the reply says nothing about a webhook
  endpoint existing. `410 Gone` or `{"error": "webhooks_disabled"}` would: an
  anonymous caller learns both that the endpoint is there and what it is for.

  It stands first in the pipeline, before `:accepts`. Choosing a format first
  would render the 404 as JSON while an unknown path renders it as HTML, and
  that difference is itself an answer to "is something here?".
  """

  alias ConfluencePhxMirror.Webhooks

  def init(opts), do: opts

  def call(conn, _opts) do
    if Webhooks.enabled?() do
      conn
    else
      raise Phoenix.Router.NoRouteError, conn: conn, router: ConfluencePhxMirrorWeb.Router
    end
  end
end
