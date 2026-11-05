defmodule ConfluencePhxMirrorWeb.PublicSpaceIdentityTest do
  @moduledoc """
  What a stranger sees on a page the deployment published.

  The decision this pins: public ⇒ anonymised. A page a stranger may open names
  nobody — no byline, no comment author, no link to a person — while a reader
  with an account reading the same page keeps what the mirror always drew.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.TestConfig

  # Both spaces are open to the site's anonymous reader; only the list separates
  # them, so what the tests below see is the list and nothing else.
  setup do
    TestConfig.put(:public_site, true)
    TestConfig.put(:public_spaces, ["OPENBOOK"])

    open = anonymous_space("OPENBOOK")
    secret = anonymous_space("SECRET")

    %{
      page: written_page(open, 91_201, "Runbook"),
      secret_page: written_page(secret, 91_202, "Salaries")
    }
  end

  test "a stranger reads the public space's page, and it names nobody", %{conn: conn, page: page} do
    body = conn |> get(page_path("OPENBOOK", page)) |> html_response(200)

    assert body =~ "Runbook"
    refute body =~ "Jane Doe"
    refute body =~ "Sam Rivera"
    refute body =~ "/people/"
  end

  test "the page beside it does not exist for them", %{conn: conn, secret_page: page} do
    assert conn |> get(page_path("SECRET", page)) |> html_response(404)
  end

  test "a reader with an account sees the same page as before", %{conn: conn, page: page} do
    body =
      conn
      |> log_in(user_fixture())
      |> get(page_path("OPENBOOK", page))
      |> html_response(200)

    assert body =~ "Jane Doe"
    assert body =~ "Sam Rivera"
  end

  test "a person's page and picture answer a stranger with the 404 of nobody there", %{
    conn: conn
  } do
    assert conn |> get(~p"/people/acc-jane") |> html_response(404)
    assert conn |> get(~p"/people/acc-jane/avatar") |> response(404)
  end

  test "the people directory sends a stranger home", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/people")
  end

  defp page_path(space_key, page) do
    URLs.page_path(space_key, page.confluence_id, page.slug)
  end

  defp anonymous_space(key) do
    space = space_fixture(%{key: key, name: "Space #{key}"})

    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "anonymous", subject_key: nil}
      ])

    space
  end

  defp written_page(space, confluence_id, title) do
    page =
      page_fixture(space, %{
        confluence_id: confluence_id,
        title: title,
        author_name: "Jane Doe",
        author_account_id: "acc-jane"
      })

    comment_fixture(page)
    page
  end
end
