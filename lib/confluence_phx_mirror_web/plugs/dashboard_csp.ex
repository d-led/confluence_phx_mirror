defmodule ConfluencePhxMirrorWeb.Plugs.DashboardCSP do
  @moduledoc """
  A content policy that lets the BEAM's own dashboard run.

  LiveDashboard ships exactly one inline script (`window.LiveDashboard =
  {customHooks: …}`) and its bundle reads that global. Under the reader pages'
  `script-src 'self'` the browser drops the script, the bundle dies with
  `undefined (reading 'customHooks')`, and the dashboard stops being live: the
  numbers still paint, because they are server-rendered, but nothing updates and
  the OS Data graphs never move.

  This route is administrator-only, and it is not compiled at all unless the
  deployment sets `admin_dashboard` — so it is the one place in the application
  where inline script is allowed, and the reader pages keep the strict policy.
  """

  @behaviour Plug

  import Plug.Conn

  @policy "default-src 'self'; script-src 'self' 'unsafe-inline'; " <>
            "style-src 'self' 'unsafe-inline'; img-src 'self' data:; " <>
            "font-src 'self' data:; connect-src 'self' ws: wss:; " <>
            "object-src 'none'; base-uri 'self'; form-action 'self'; " <>
            "frame-ancestors 'none'"

  @impl true
  def init(opts), do: opts

  # The policy is above, and it is deliberate: see the moduledoc.
  # sobelow_skip ["Config.CSP"]
  @impl true
  def call(conn, _opts), do: put_resp_header(conn, "content-security-policy", @policy)
end
