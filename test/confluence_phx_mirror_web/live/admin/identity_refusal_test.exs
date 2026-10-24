defmodule ConfluencePhxMirrorWeb.Live.Admin.IdentityRefusalTest do
  @moduledoc """
  What the identity picker says when a link is refused, in the words an
  administrator can act on: whose the identity already is, or that the site has
  not shown it yet.

  A refusal is not an error page — the click stays where it was and the sentence
  arrives as a flash — so the only place to hold the sentences is here.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts

  test "an identity another account already holds names that account", %{conn: conn} do
    admin = Accounts.ensure_admin!()
    holder = user_fixture(%{email: "holder@example.com"})
    picker = user_fixture(%{email: "picker@example.com"})

    known_identity("acc-taken")
    {:ok, _holder} = Accounts.link_identity(holder, "acc-taken", {:user, admin})

    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "confirm_link", %{
        "user_id" => to_string(picker.id),
        "account_id" => "acc-taken"
      })

    assert html =~ "acc-taken belongs to holder@example.com. Unlink it there first."
  end

  test "an identity the mirror has never seen asks for a sync", %{conn: conn} do
    picker = user_fixture(%{email: "picker@example.com"})

    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "confirm_link", %{
        "user_id" => to_string(picker.id),
        "account_id" => "acc-never-seen"
      })

    assert html =~ "The mirror has not seen acc-never-seen yet — run a sync."
  end

  test "linking the same identity twice says it is already this account's", %{conn: conn} do
    admin = Accounts.ensure_admin!()
    picker = user_fixture(%{email: "picker@example.com"})

    known_identity("acc-known")
    {:ok, _picker} = Accounts.link_identity(picker, "acc-known", {:user, admin})

    {:ok, view, _html} = live(conn, ~p"/admin/users")

    html =
      render_submit(view, "confirm_link", %{
        "user_id" => to_string(picker.id),
        "account_id" => "acc-known"
      })

    assert html =~ "That identity already belongs to this account."
  end

  # An identity the sync has shown: a page Confluence attributes to it is enough
  # for the mirror to know the account exists (`Mirror.identity_known?/1`).
  defp known_identity(account_id) do
    page_fixture(space_fixture(), %{author_name: "The Person", author_account_id: account_id})
  end
end
