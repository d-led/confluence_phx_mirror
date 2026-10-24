defmodule ConfluencePhxMirrorWeb.AccessTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror

  setup do
    demo_snapshot!()
    # Readers are anonymous unless a test signs them in; administrators bypass
    # every permission check.
    previous = Application.get_env(:confluence_phx_mirror, :auto_admin)
    Application.put_env(:confluence_phx_mirror, :auto_admin, false)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :auto_admin, previous) end)
    :ok
  end

  test "a page restricted to a group is not found for anonymous readers", %{conn: conn} do
    assert conn
           |> get(~p"/spaces/ENG/pages/#{Demo.restricted_page()}/#{Demo.restricted_page_slug()}")
           |> html_response(404)
  end

  test "a space restricted to signed-in users is not found and not listed", %{conn: conn} do
    assert conn |> get(~p"/spaces/PROD") |> html_response(404)

    body = conn |> get(~p"/spaces") |> html_response(200)
    refute body =~ "Product Hub"
  end

  test "a restricted space's icon is not served either", %{conn: conn} do
    blob_key = Key.space_icon("PROD", "image/svg+xml")
    {:ok, ^blob_key} = Store.put(blob_key, "<svg/>")

    {:ok, _space} =
      Mirror.upsert_space(%{
        key: "PROD",
        name: "Product Hub",
        icon_blob_key: blob_key,
        icon_media_type: "image/svg+xml"
      })

    assert conn |> get(~p"/spaces/PROD/icon") |> response(404) == "This space has no icon."
  end

  test "an open page is still served to anonymous readers", %{conn: conn} do
    body =
      conn
      |> get(~p"/spaces/ENG/pages/#{Demo.open_page()}/#{Demo.open_page_slug()}")
      |> html_response(200)

    assert body =~ "Architecture Overview"
  end

  test "the space catalog lists only pages the reader may open", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/spaces/ENG/pages")

    assert has_element?(view, "a[href^='/spaces/ENG/pages/#{Demo.open_page()}']")
    refute has_element?(view, "a[href^='/spaces/ENG/pages/#{Demo.restricted_page()}']")
  end

  test "the home rail does not advertise a restricted space", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ "Engineering Handbook"
    refute body =~ "Product Hub"
  end

  # A reader may open a space and still not open every page in it. Every list a
  # page draws of other pages — a rail, a count, a chip, a crumb — is a claim
  # about pages, so none of them may name one its reader cannot open.
  describe "a space overview lists only pages its reader may open" do
    test "the recently updated rail leaves out a restricted page", %{conn: conn} do
      overview = overview(conn)

      assert overview =~ Demo.open_page_parent_title()
      refute overview =~ Demo.restricted_page_title()
    end

    test "a label only a restricted page carries is not offered", %{conn: conn} do
      refute overview(conn) =~ ~s(href="/labels/#{Demo.restricted_page_label()}")
    end

    test "a shared label counts the pages behind it the reader may open", %{conn: conn} do
      assert chip_count(overview(conn), Demo.shared_label()) == 1
    end

    test "an administrator sees the whole space", %{conn: conn} do
      overview =
        conn
        |> sign_in_as_admin()
        |> get(~p"/spaces/ENG/overview")
        |> html_response(200)

      assert overview =~ Demo.restricted_page_title()
      assert chip_count(overview, Demo.shared_label()) == 2
    end
  end

  describe "a page names only pages its reader may open" do
    test "the child list and its count leave out a restricted sibling", %{conn: conn} do
      children =
        conn
        |> page_document(Demo.open_page_parent(), Demo.open_page_parent_slug())
        |> LazyHTML.query("nav[aria-label='Child pages']")

      assert text(children) =~ Demo.open_page_title()
      refute text(children) =~ Demo.restricted_page_title()

      # Two pages sit below this one, one of them behind the restriction, so the
      # count is the half the reader may open.
      assert children |> LazyHTML.query(".badge") |> LazyHTML.text() |> String.trim() == "1"
    end

    test "the outgoing links leave out a link to a restricted page", %{conn: conn} do
      rail =
        conn
        |> page_document(Demo.crosslinks_page(), Demo.crosslinks_page_slug())
        |> LazyHTML.query("#outgoing-links")

      assert text(rail) =~ Demo.open_page_title()
      refute text(rail) =~ Demo.restricted_page_title()
    end

    test "the backlinks leave out a page the reader may not open", %{conn: conn} do
      rail =
        conn
        |> page_document(Demo.open_page(), Demo.open_page_slug())
        |> LazyHTML.query("#backlinks")

      assert text(rail) =~ "Engineering Handbook"
      refute text(rail) =~ Demo.restricted_page_title()
    end

    test "the breadcrumb trail leaves out a restricted ancestor", %{conn: conn} do
      page = a_page_below_the_restricted_one()

      trail =
        conn
        |> page_document(page.confluence_id, page.slug)
        |> LazyHTML.query("nav[aria-label='Breadcrumb']")

      assert text(trail) =~ Demo.open_page_parent_title()
      refute text(trail) =~ Demo.restricted_page_title()
    end
  end

  defp overview(conn), do: conn |> get(~p"/spaces/ENG/overview") |> html_response(200)

  defp page_document(conn, id, slug) do
    conn
    |> get(~p"/spaces/ENG/pages/#{id}/#{slug}")
    |> html_response(200)
    |> LazyHTML.from_fragment()
  end

  # The chips under "Labels" are a name and the number of pages carrying it.
  defp chip_count(html, label) do
    chip =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s(a[href="/labels/#{label}"]))
      |> LazyHTML.text()

    chip |> String.split() |> List.last() |> String.to_integer()
  end

  # A page that sits below the restricted one: its own row is readable, so the
  # trail is what would otherwise tell its reader about a page they cannot open.
  defp a_page_below_the_restricted_one do
    space = Mirror.get_space!("ENG")

    page_fixture(space, %{
      confluence_id: 7001,
      title: "Tooling Notes",
      ancestors: [Demo.open_page_parent_number(), Demo.restricted_page_number()]
    })
  end

  defp sign_in_as_admin(conn) do
    admin = user_fixture(%{email: "overview-admin@example.com", role: "admin"})
    init_test_session(conn, %{user_id: admin.id})
  end

  defp text(html), do: LazyHTML.text(html)
end
