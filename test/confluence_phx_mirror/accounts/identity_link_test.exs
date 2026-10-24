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
    {:ok, reader} = Accounts.link_identity(reader, @guest, {:system, "test"})

    assert Authorization.can_read_page?(Scope.for_user(reader), page)
  end

  test "unlinking takes the grant away again" do
    page = Mirror.get_page!(Demo.restricted_page_number())
    reader = user_fixture(%{email: "unlinked@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, {:system, "test"})

    {:ok, reader} = Accounts.unlink_identity(reader, @guest, {:system, "test"})

    refute Authorization.can_read_page?(Scope.for_user(reader), page)
  end

  test "an identity belongs to one account" do
    holder = user_fixture(%{email: "holder@example.com"})
    other = user_fixture(%{email: "other@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, _} = Accounts.link_identity(holder, @guest, {:system, "test"})

    assert {:error, {:linked_elsewhere, holder_now}} =
             Accounts.link_identity(other, @guest, {:system, "test"})

    assert holder_now.id == holder.id
    assert Accounts.accounts_linked_to(@guest) |> Enum.map(& &1.id) == [holder.id]
  end

  test "an identity the mirror has never seen is refused" do
    reader = user_fixture(%{email: "typo@example.com"})

    assert {:error, :unknown_identity} =
             Accounts.link_identity(reader, "not-an-account", {:system, "test"})

    assert Accounts.get_user(reader.id).identity_account_ids == []
  end

  test "linking the same identity twice says so instead of linking twice" do
    reader = user_fixture(%{email: "twice@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, {:system, "test"})

    assert {:error, :already_linked} =
             Accounts.link_identity(reader, @guest, {:system, "test"})
  end

  test "the link is in the audit log, with the identity named" do
    reader = user_fixture(%{email: "audited@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])

    {:ok, _} = Accounts.link_identity(reader, @guest, {:user, reader})

    entry = Audit.recent(1) |> hd()
    assert entry.action == "user.identity_linked"
    assert entry.entity_id == to_string(reader.id)
    assert entry.metadata["identity"] == @guest
  end

  test "an identity linked to an account is one of its identities, not another account's" do
    reader = user_fixture(%{email: "keys@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, {:system, "test"})

    assert @guest in User.identity_keys(reader)
    assert "keys@example.com" in User.identity_keys(reader)
  end

  test "the API answers with the same permissions as the page, token or not" do
    page = Mirror.get_page!(Demo.restricted_page_number())
    reader = user_fixture(%{email: "api.linked@example.com"})
    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])
    {:ok, reader} = Accounts.link_identity(reader, @guest, {:system, "test"})

    {:ok, plain, _token} = Accounts.create_api_token(reader, "cli", {:system, "test"})
    {:ok, token_user} = Accounts.authenticate_api_token(plain)

    # The token's own road to the user row must carry the identities too: a
    # token that answered with less than the browser would be a silent demotion.
    assert Authorization.can_read_page?(Scope.for_user(token_user), page)
  end
end
