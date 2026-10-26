defmodule ConfluencePhxMirror.Mirror.SpaceAccessGrantTest do
  @moduledoc """
  Access the site narrows can be widened here, on purpose and on the record.

  Everything else about access is replayed from Confluence. These cases pin the
  exception: a grant is one row an administrator added, the sync never removes
  it, and it opens no door the site did not already have a key for — it only lets
  one more reader through one that was narrowed.
  """

  use ConfluencePhxMirror.DataCase, async: true

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror

  setup do
    # A space narrowed to one group, and two people: one in it, one not.
    space = space_fixture(%{key: "GRANTS"})

    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "group", subject_key: "confluence-users"}
      ])

    {:ok, _} = Mirror.replace_group_members("confluence-users", [%{email: "inside@example.com"}])

    # The person a grant is for is somebody the site names — in another group,
    # which is what makes them a reader the mirror can vouch for.
    {:ok, _} = Mirror.replace_group_members("all-staff", [%{email: "outside@example.com"}])

    %{
      space: space,
      inside: user_fixture(%{email: "inside@example.com"}),
      outside: user_fixture(%{email: "outside@example.com"}),
      admin: user_fixture(%{email: "grant.admin@example.com", role: "admin"})
    }
  end

  test "a grant lets one more reader into a space the site narrowed", %{
    space: space,
    outside: outside,
    admin: admin
  } do
    refute Authorization.can_read_space?(Scope.for_user(outside), space)

    {:ok, _} = Mirror.grant_space_access(space, "user", outside.email, {:user, admin})

    assert Authorization.can_read_space?(Scope.for_user(outside), space)
  end

  test "the sync replaces its own rows and leaves the grant alone", %{
    space: space,
    outside: outside,
    admin: admin
  } do
    {:ok, _} = Mirror.grant_space_access(space, "user", outside.email, {:user, admin})

    # What the next run does to the space.
    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "group", subject_key: "confluence-users"}
      ])

    assert Authorization.can_read_space?(Scope.for_user(outside), space)
    assert [%{subject_key: key}] = Mirror.space_grants_here(space)
    assert key == outside.email
  end

  test "taking the grant away takes the access away", %{
    space: space,
    outside: outside,
    admin: admin
  } do
    {:ok, _} = Mirror.grant_space_access(space, "user", outside.email, {:user, admin})
    {:ok, _} = Mirror.revoke_space_access(space, "user", outside.email, {:user, admin})

    refute Authorization.can_read_space?(Scope.for_user(outside), space)

    assert {:error, :not_granted} =
             Mirror.revoke_space_access(space, "user", outside.email, {:user, admin})
  end

  test "only an administrator may grant or revoke", %{
    space: space,
    outside: outside,
    inside: inside
  } do
    assert {:error, :not_authorized} =
             Mirror.grant_space_access(space, "user", outside.email, {:user, inside})

    assert {:error, :not_authorized} =
             Mirror.revoke_space_access(space, "user", outside.email, {:system, "sync"})
  end

  test "a space that is open cannot be granted — there is nothing to widen", %{
    outside: outside,
    admin: admin
  } do
    open = space_fixture(%{key: "OPEN"})

    assert {:error, :space_is_open} =
             Mirror.grant_space_access(open, "user", outside.email, {:user, admin})
  end

  test "a personal space stays its owner's, grant or no grant", %{
    outside: outside,
    admin: admin
  } do
    personal = space_fixture(%{key: "~5F057CBE0B38B10022628D68", type: "personal"})

    assert {:error, :space_is_open} =
             Mirror.grant_space_access(personal, "user", outside.email, {:user, admin})

    refute Authorization.can_read_space?(Scope.for_user(outside), personal)
  end

  test "the grant is in the audit log, with the reader named", %{
    space: space,
    outside: outside,
    admin: admin
  } do
    {:ok, _} = Mirror.grant_space_access(space, "user", outside.email, {:user, admin})

    entry = Audit.recent(1) |> hd()
    assert entry.action == "space.access_granted"
    assert entry.entity_id == space.key
    assert entry.metadata["subject"] == outside.email
  end

  describe "a page" do
    # A page's restriction is asked after the space's, so the page cases live in
    # an open space: they are about the page's own answer, not the space's.
    setup do
      space = space_fixture(%{key: "PAGEGRANTS"})
      page = page_fixture(space, %{title: "Salaries"})

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"}
        ])

      %{page: page, space: space}
    end

    test "a grant lets one more reader onto a restricted page", %{
      page: page,
      outside: outside,
      admin: admin
    } do
      refute Authorization.can_read_page?(Scope.for_user(outside), page)

      {:ok, _} = Mirror.grant_page_access(page, "user", outside.email, {:user, admin})

      assert Authorization.can_read_page?(Scope.for_user(outside), page)
    end

    test "the sync leaves the page grant alone", %{page: page, outside: outside, admin: admin} do
      {:ok, _} = Mirror.grant_page_access(page, "user", outside.email, {:user, admin})

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"}
        ])

      assert Authorization.can_read_page?(Scope.for_user(outside), page)
    end

    test "a page the site opens again takes its grants with it", %{
      page: page,
      outside: outside,
      admin: admin
    } do
      {:ok, _} = Mirror.grant_page_access(page, "user", outside.email, {:user, admin})
      {:ok, _} = Mirror.replace_page_restrictions(page, [])

      assert Mirror.page_grants(page).granted == []
    end

    test "an unrestricted page cannot be granted", %{space: space, outside: outside, admin: admin} do
      open = page_fixture(space, %{title: "Handbook"})

      assert {:error, :page_is_open} =
               Mirror.grant_page_access(open, "user", outside.email, {:user, admin})
    end

    test "only an administrator may grant on a page", %{
      page: page,
      outside: outside,
      inside: inside
    } do
      assert {:error, :not_authorized} =
               Mirror.grant_page_access(page, "user", outside.email, {:user, inside})
    end

    test "the page grant is in the audit log", %{page: page, outside: outside, admin: admin} do
      {:ok, _} = Mirror.grant_page_access(page, "user", outside.email, {:user, admin})

      entry = Audit.recent(1) |> hd()
      assert entry.action == "page.access_granted"
      assert entry.entity_id == page.title
    end
  end

  test "the screen's answer keeps the site's rows and ours apart", %{
    space: space,
    outside: outside,
    admin: admin
  } do
    {:ok, _} = Mirror.grant_space_access(space, "user", outside.email, {:user, admin})

    grants = Mirror.space_grants(space)

    assert grants.groups == ["confluence-users"]
    assert grants.granted |> Enum.map(& &1.subject_key) == [outside.email]
    assert Accounts.get_user(outside.id).email in Enum.map(grants.granted, & &1.subject_key)
  end
end
