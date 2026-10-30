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
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.{Scope, User}
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mail.Budget
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Settings

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
        %{account_id: @guest, display_name: "Guest Visitor"},
        %{account_id: "557058:maria", display_name: "Maria Sanchez"}
      ])

    # Both identities are named by the content, which is what `people/1` lists.
    space = space_fixture()

    page_fixture(space, %{author_name: "Guest Visitor", author_account_id: @guest})
    page_fixture(space, %{author_name: "Maria Sanchez", author_account_id: "557058:maria"})

    assert [%{display_name: "Guest Visitor"}] = Mirror.people(query: "guest")
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

    # The note about the mail is the newest line, so the link's own entry is
    # found by name rather than by position.
    entry = Enum.find(Audit.recent(5), &(&1.action == "user.identity_linked"))
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

  describe "the note a link sends" do
    test "both ends that have an address hear about it" do
      reader = user_fixture(%{email: "both.ends@example.com"})

      {:ok, _} =
        Mirror.replace_group_members("confluence-users", [
          %{account_id: @guest, email: "guest.owner@example.com", display_name: "Guest Person"}
        ])

      {:ok, _} = Accounts.link_identity(reader, @guest, admin_actor())

      emails = sent_emails()
      assert Enum.map(emails, &address/1) == ["both.ends@example.com", "guest.owner@example.com"]

      # Whoever reads it has to be able to tell which identity, for which
      # account — the name for a person, the id for the site — and both ends
      # are told the same thing about the same link.
      Enum.each(emails, fn email ->
        assert email.subject == "[Mirror] A Confluence identity was linked"
        assert email.text_body =~ "Guest Person — #{@guest}"
        assert email.text_body =~ "both.ends@example.com"
      end)
    end

    test "an identity the mirror holds no address for tells only the account" do
      reader = user_fixture(%{email: "only.account@example.com"})
      {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])

      {:ok, _} = Accounts.link_identity(reader, @guest, admin_actor())

      assert Enum.map(sent_emails(), &address/1) == ["only.account@example.com"]
    end

    test "an identity that is the account's own address is one message" do
      reader = user_fixture(%{email: "one.inbox@example.com"})

      {:ok, _} =
        Mirror.replace_group_members("confluence-users", [
          %{account_id: @guest, email: "One.Inbox@Example.com"}
        ])

      {:ok, _} = Accounts.link_identity(reader, @guest, admin_actor())

      assert Enum.map(sent_emails(), &address/1) == ["one.inbox@example.com"]
    end

    test "a day with no room for the note still makes the link" do
      reader = user_fixture(%{email: "no.room@example.com"})
      {:ok, _} = Mirror.replace_group_members("confluence-users", [%{account_id: @guest}])

      # The day's allowance is one message, and it is already spent: the note is
      # a message like any other, and a link is not something a relay can veto.
      Settings.update(%{"mail.per_day" => "1"}, {:system, "test"})
      on_exit(fn -> Settings.reload() end)
      assert {:ok, _} = Budget.claim("something:else")

      assert {:ok, user} = Accounts.link_identity(reader, @guest, admin_actor())

      assert user.identity_account_ids == [@guest]
      refute_email_sent()
    end
  end

  # The messages this test's link produced, in the order they were sent.
  defp sent_emails do
    receive do
      {:email, %Swoosh.Email{} = email} -> [email | sent_emails()]
    after
      0 -> []
    end
  end

  defp address(%Swoosh.Email{to: [{_name, address} | _]}), do: address
end
