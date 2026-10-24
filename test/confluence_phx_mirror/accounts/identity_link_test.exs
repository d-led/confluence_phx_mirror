defmodule ConfluencePhxMirror.Accounts.IdentityLinkTest do
  @moduledoc """
  One person, several Confluence identities.

  A person often holds two Atlassian accounts — a personal one and a guest one —
  and both can be named by the content and by the permissions. Linking says
  "this identity is this account"; what the identity may read becomes the
  account's, which is the union `User.identity_keys/1` answers with.

  The cases below are the rules: the union is a real grant, an identity belongs
  to one account only, a typo cannot become a grant, and unlinking takes the
  grant away again. The last test asks the same question through the API as
  through a signed-in page, because a token loads its user by another road and
  must not answer differently.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Scope, User}
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror

  @guest "5f057cbe0b38b10022628d68"
  @author "557058:maria"

  # Linking is an administrator's decision, so the domain tests act as one.
  defp admin_actor, do: {:user, user_fixture(%{email: "link.admin@example.com", role: "admin"})}

  setup do
    demo_snapshot!()
    :ok
  end

  test "linking an identity grants what that identity may read" do
    page = Mirror.get_page!(Demo.restricted_page_number())
    reader = user_fixture(%{email: "linked@example.com"})

    refute Authorization.can_read_page?(Scope.for_user(reader), page)

    # The guest identity is in the group the restricted page names.
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, admin_actor())

    assert Authorization.can_read_page?(Scope.for_user(reader), page)
  end

  test "only an administrator may link or unlink" do
    reader = user_fixture(%{email: "member.reader@example.com"})
    member = user_fixture(%{email: "just.a.member@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, admin_actor())

    assert {:error, :not_authorized} =
             Accounts.link_identity(reader, "557058:someone", {:user, member})

    assert {:error, :not_authorized} = Accounts.unlink_identity(reader, @guest, {:user, member})

    # A caller with no reader behind it is refused too: an API or MCP surface has
    # to hand over the reader it acts for, and inherits this answer.
    assert {:error, :not_authorized} = Accounts.unlink_identity(reader, @guest, {:system, "test"})

    assert Accounts.get_user(reader.id).identity_account_ids == [@guest]
  end

  test "the identity list is searched by name and by account id" do
    {:ok, _} =
      Mirror.replace_group_members("confluence-users", [
        %{account_id: @guest, display_name: "Guest Ledentsov"},
        %{account_id: "557058:maria", display_name: "Maria Sanchez"}
      ])

    # Both identities are named by the content, which is what `people/1` lists.
    space = space_fixture()

    page_fixture(space, %{author_name: "Guest Ledentsov", author_account_id: @guest})
    page_fixture(space, %{author_name: "Maria Sanchez", author_account_id: "557058:maria"})

    assert [%{display_name: "Guest Ledentsov"}] = Mirror.people(query: "guest")
    assert [%{account_id: "557058:maria"}] = Mirror.people(query: "557058:maria")
    assert Mirror.people(query: "nobody") == []
    assert Mirror.count_people(query: "guest") == 1

    # The count the screen says is the size of the list it would draw.
    assert Mirror.count_people(query: "") == length(Mirror.people())
  end

  test "unlinking takes the grant away again" do
    page = Mirror.get_page!(Demo.restricted_page_number())
    reader = user_fixture(%{email: "unlinked@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, admin_actor())

    {:ok, reader} = Accounts.unlink_identity(reader, @guest, admin_actor())

    refute Authorization.can_read_page?(Scope.for_user(reader), page)
  end

  test "an identity belongs to one account" do
    holder = user_fixture(%{email: "holder@example.com"})
    other = user_fixture(%{email: "other@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, _} = Accounts.link_identity(holder, @guest, admin_actor())

    assert {:error, {:linked_elsewhere, holder_now}} =
             Accounts.link_identity(other, @guest, admin_actor())

    assert holder_now.id == holder.id
    assert Accounts.accounts_linked_to(@guest) |> Enum.map(& &1.id) == [holder.id]
  end

  test "an identity the mirror has never seen is refused" do
    reader = user_fixture(%{email: "typo@example.com"})

    assert {:error, :unknown_identity} =
             Accounts.link_identity(reader, "not-an-account", admin_actor())

    assert Accounts.get_user(reader.id).identity_account_ids == []
  end

  test "an identity the content names as an author can be linked" do
    reader = user_fixture(%{email: "author@example.com"})
    page_fixture(space_fixture(), %{author_name: "Maria Sanchez", author_account_id: @author})

    {:ok, reader} = Accounts.link_identity(reader, @author, admin_actor())

    assert @author in User.identity_keys(reader)
  end

  test "linking the same identity twice says so instead of linking twice" do
    reader = user_fixture(%{email: "twice@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, admin_actor())

    assert {:error, :already_linked} =
             Accounts.link_identity(reader, @guest, admin_actor())
  end

  test "the link is in the audit log, with the identity named" do
    reader = user_fixture(%{email: "audited@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])

    {:ok, _} = Accounts.link_identity(reader, @guest, admin_actor())

    entry = Audit.recent(1) |> hd()
    assert entry.action == "user.identity_linked"
    assert entry.entity_id == to_string(reader.id)
    assert entry.metadata["identity"] == @guest
  end

  test "an identity linked to an account is one of its identities, not another account's" do
    reader = user_fixture(%{email: "keys@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, admin_actor())

    assert @guest in User.identity_keys(reader)
    assert "keys@example.com" in User.identity_keys(reader)
  end

  test "the API answers with the same permissions as the page, token or not" do
    page = Mirror.get_page!(Demo.restricted_page_number())
    reader = user_fixture(%{email: "api.linked@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, admin_actor())

    {:ok, plain, _token} = Accounts.create_api_token(reader, "cli", admin_actor())
    {:ok, token_user} = Accounts.authenticate_api_token(plain)

    # The token's own road to the user row must carry the identities too: a
    # token that answered with less than the browser would be a silent demotion.
    assert Authorization.can_read_page?(Scope.for_user(token_user), page)
  end
end
