defmodule ConfluencePhxMirrorWeb.Plugs.DashboardWayBack do
  @moduledoc """
  Puts a way back onto the BEAM dashboard's pages.

  LiveDashboard draws its own page — its own `<head>`, its own sidebar, its own
  footer — and `Phoenix.LiveDashboard.Router` takes options for the metrics, the
  repositories, the environment keys and the title, none of which is a link
  home. In a browser that costs nothing: the address bar is the way back. This
  application also ships as a window with no address bar (see
  `docs/desktop-tool.md`), and there the dashboard is the one screen with no
  exit.

  So the page leaves this module with one element added to it: a link to the
  admin cockpit, fixed in the top-right corner. It is styled inline because the
  dashboard's stylesheet is the dashboard's — a class of ours would mean
  shipping a rule into a page whose assets this application does not own.

  It goes in after the opening `<body>` tag, which is outside the element
  LiveView patches, so a patch between dashboard pages cannot take it away. A
  document navigation and not a live one: the cockpit is another `live_session`
  on another socket, and a patch across that boundary is a page load anyway.
  """

  @behaviour Plug

  import Plug.Conn, only: [get_resp_header: 2, register_before_send: 2]

  # One string rather than a list of assignments, because there is nowhere in
  # this page that a stylesheet could own it. `:where` would beat it; nothing
  # does.
  @style Enum.join(
           [
             "position: fixed",
             "top: .5rem",
             "right: .75rem",
             "z-index: 1030",
             "display: inline-flex",
             "align-items: center",
             "gap: .35rem",
             "padding: .4rem .7rem",
             "border-radius: .5rem",
             "font: 600 .8125rem/1.2 system-ui, -apple-system, sans-serif",
             "color: #fff",
             "background: #4f46e5",
             "text-decoration: none",
             "box-shadow: 0 1px 3px rgb(0 0 0 / 0.25)"
           ],
           "; "
         )

  @impl true
  def init(opts), do: Map.new(opts)

  # `<body>` is not what a development page says. Phoenix annotates every tag it
  # renders there (`<body phx-r="1">`, which is what makes a page's markup
  # traceable back to the template that drew it), so the opening tag is matched
  # with whatever attributes it carries — and a page whose body tag cannot be
  # found comes back untouched rather than mangled.
  @body_tag ~r/<body[^>]*>/

  @impl true
  def call(conn, opts), do: register_before_send(conn, &put_way_back(&1, opts))

  defp put_way_back(%Plug.Conn{status: 200} = conn, opts) do
    if html?(conn) do
      # The body a LiveView rendered arrives as iodata, so it is a list until it
      # is asked to be a page.
      body =
        Regex.replace(
          @body_tag,
          IO.iodata_to_binary(conn.resp_body),
          fn tag -> tag <> bar(opts) end,
          global: false
        )

      %{conn | resp_body: body}
    else
      conn
    end
  end

  # Every other answer is the dashboard's own: a redirect, an error, an asset.
  defp put_way_back(conn, _opts), do: conn

  defp html?(conn) do
    case get_resp_header(conn, "content-type") do
      [content_type | _] -> String.starts_with?(content_type, "text/html")
      [] -> false
    end
  end

  defp bar(%{back: back, label: label}) do
    ~s(<a id="dashboard-way-back" href="#{escape(back)}" style="#{@style}">← #{escape(label)}</a>)
  end

  # The two options are the router's own literals, so this escapes nothing in
  # practice; it is here so that a caller who passes something else cannot write
  # markup into a page.
  defp escape(value), do: Plug.HTML.html_escape(value)
end
