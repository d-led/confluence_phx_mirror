defmodule ConfluencePhxMirrorWeb.Admin.DashboardWayBackTest do
  @moduledoc """
  The BEAM dashboard is the one page of this application a dependency draws, and
  the one page that is not reached by a live navigation: it is its own
  `live_session`, on its own socket. Both facts are what a reader is left with —
  a screen with no way back to the cockpit, which in the desktop window (no
  address bar, no back button) is a screen with no exit at all.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirrorWeb.Plugs.DashboardWayBack

  setup %{conn: conn} do
    ops = user_fixture(%{role: "admin"})

    {:ok, conn: log_in(conn, ops)}
  end

  test "the dashboard says how to get back to the cockpit", %{conn: conn} do
    page = conn |> get("/admin/runtime/home") |> html_response(200)

    assert way_back(page) |> LazyHTML.attribute("href") == ["/admin"]
  end

  # Development is where a reader meets the dashboard, and it is where Phoenix
  # annotates every tag it renders: the page's body tag is `<body phx-r="1">`,
  # not `<body>`. A link added only to an unannotated page is a link nobody
  # sees, which is how this one first went missing in a sibling project.
  test "the link goes in after a body tag that carries attributes", %{conn: conn} do
    plug = DashboardWayBack.init(back: "/admin", label: "Admin")

    body =
      conn
      |> put_resp_content_type("text/html")
      |> resp(200, ~s(<html><body phx-r="1"><main>the dashboard</main></body></html>))
      |> DashboardWayBack.call(plug)
      |> send_resp()
      |> Map.fetch!(:resp_body)

    assert body =~ ~s(<body phx-r="1"><a id="dashboard-way-back")
  end

  test "a page with no body tag comes back untouched, not mangled", %{conn: conn} do
    plug = DashboardWayBack.init(back: "/admin", label: "Admin")
    page = "<html><p>not a page this plug knows</p></html>"

    body =
      conn
      |> put_resp_content_type("text/html")
      |> resp(200, page)
      |> DashboardWayBack.call(plug)
      |> send_resp()
      |> Map.fetch!(:resp_body)

    assert body == page
  end

  # The database page lists a repository only when that database's extras module
  # is loaded (`Phoenix.LiveDashboard.EctoStatsPage`), which is what makes the
  # pair of extras packages a dependency and not a nicety: without them the page
  # says no repository is running, on a node that has been querying one all day.
  test "the database page names this application's repository", %{conn: conn} do
    page = conn |> get("/admin/runtime/ecto_stats") |> html_response(200)

    assert page =~ "ConfluencePhxMirror.Repo"
    refute page =~ "No Ecto repository was found running"
  end

  defp way_back(page) do
    page
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#dashboard-way-back")
  end
end
