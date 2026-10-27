defmodule ConfluencePhxMirrorWeb.Api.V1.IdentityApiTest do
  @moduledoc """
  The identities API: what the mirror knows about the people Confluence names,
  and pairing one of them with an account here.

  Reading and writing are both an administrator's. Linking is an access
  decision — it hands an account everything the identity may read — so the
  refusals matter as much as the success: a typo must not become a grant, and
  one identity must not end up standing for two accounts.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Repo

  # The identity the tests below work with: a person the content names, with a
  # group the last sync read, and no account behind it.
  @maria "557058:maria"
  @maria_name "Maria Sanchez"

  setup %{conn: conn} do
    demo_snapshot!()

    space = space_fixture()
    page_fixture(space, %{author_name: @maria_name, author_account_id: @maria})

    {:ok, _} =
      Mirror.replace_group_members("eng-readers", [
        %{account_id: @maria, display_name: @maria_name}
      ])

    {:ok, conn: log_in_admin(conn)}
  end

  test "an administrator reads the identities the content names, with their groups",
       %{conn: conn} do
    body = conn |> get(~p"/api/v1/identities?q=maria") |> json_response(200)

    assert body["total"] == 1
    assert body["limit"] == 25

    assert [maria] = body["items"]
    assert maria["accountId"] == @maria
    assert maria["displayName"] == @maria_name
    assert maria["groups"] == ["eng-readers"]
    assert maria["linkedTo"] == nil
  end

  test "the list is paged, because a site names more people than a screen can draw",
       %{conn: conn} do
    window = conn |> get(~p"/api/v1/identities?limit=1&offset=1") |> json_response(200)

    assert length(window["items"]) == 1
    assert window["offset"] == 1
    assert window["limit"] == 1
    assert window["total"] > 1
  end

  test "linking stands an account on an identity", %{conn: conn} do
    reader = user_fixture(%{email: "maria@example.com"})

    body =
      conn
      |> json_post("/api/v1/identities/#{@maria}/link", %{"user_id" => reader.id})
      |> json_response(200)

    assert body["identity"]["accountId"] == @maria
    assert body["identity"]["linkedTo"]["email"] == "maria@example.com"
    assert body["account"]["id"] == reader.id

    assert Accounts.get_user(reader.id).identity_account_ids == [@maria]
  end

  test "an account can also be named by its e-mail, which is what an administrator has at hand",
       %{conn: conn} do
    reader = user_fixture(%{email: "maria@example.com"})

    body =
      conn
      |> json_post("/api/v1/identities/#{@maria}/link", %{"email" => "maria@example.com"})
      |> json_response(200)

    assert body["account"]["id"] == reader.id
    assert Accounts.get_user(reader.id).identity_account_ids == [@maria]
  end

  test "an identity the mirror has never seen is a 404, not a grant that quietly does nothing",
       %{conn: conn} do
    reader = user_fixture()

    body =
      conn
      |> json_post("/api/v1/identities/557058:no-such-person/link", %{"user_id" => reader.id})
      |> json_response(404)

    assert body["error"] == "unknown_identity"
    assert Accounts.get_user(reader.id).identity_account_ids == []
  end

  test "an identity another account already holds is refused", %{conn: conn} do
    first = user_fixture(%{email: "first@example.com"})
    second = user_fixture(%{email: "second@example.com"})
    {:ok, _} = Accounts.link_identity(first, @maria, {:user, admin()})

    body =
      conn
      |> json_post("/api/v1/identities/#{@maria}/link", %{"user_id" => second.id})
      |> json_response(409)

    assert body["error"] == "linked_elsewhere"
    assert body["message"] =~ "first@example.com"
  end

  test "unlinking takes the identity's access away again", %{conn: conn} do
    reader = user_fixture(%{email: "maria@example.com"})
    {:ok, _} = Accounts.link_identity(reader, @maria, {:user, admin()})

    body = conn |> delete(~p"/api/v1/identities/#{@maria}/link") |> json_response(200)

    assert body["identity"]["linkedTo"] == nil
    assert Accounts.get_user(reader.id).identity_account_ids == []
  end

  test "the identity an account signs in with is not a link, and cannot be taken away",
       %{conn: conn} do
    reader = user_fixture(%{email: "maria@example.com"})

    reader
    |> User.identity_changeset(%{confluence_account_id: @maria})
    |> Repo.update!()

    body = conn |> delete(~p"/api/v1/identities/#{@maria}/link") |> json_response(409)

    assert body["error"] == "not_a_link"
    assert body["message"] =~ "signs in with"
    assert Accounts.get_user(reader.id).confluence_account_id == @maria
  end

  test "unlinking an identity nobody stands on says so", %{conn: conn} do
    body = conn |> delete(~p"/api/v1/identities/#{@maria}/link") |> json_response(404)

    assert body["error"] == "not_linked"
  end

  test "reading and writing are an administrator's: a reader's own token is refused", %{
    conn: conn
  } do
    {:ok, plain, _token} = reader_token()

    body =
      conn
      |> put_req_header("authorization", "Bearer #{plain}")
      |> get(~p"/api/v1/identities")
      |> json_response(403)

    assert body["error"] == "not_authorized"

    body =
      conn
      |> put_req_header("authorization", "Bearer #{plain}")
      |> json_post("/api/v1/identities/#{@maria}/link", %{"email" => "maria@example.com"})
      |> json_response(403)

    assert body["error"] == "not_authorized"
  end

  defp json_post(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  # A signed-in reader who does not administer the mirror: a token loads its own
  # user, so no `auto_admin` applies.
  defp reader_token do
    user = user_fixture(%{email: "reader@example.com", role: "member"})
    Accounts.create_api_token(user, "a test", {:system, "test"})
  end

  defp admin do
    Accounts.get_user_by_email("ops@example.com") ||
      user_fixture(%{email: "ops@example.com", role: "admin"})
  end
end
