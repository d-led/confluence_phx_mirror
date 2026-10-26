defmodule ConfluencePhxMirror.Mirror.PermissionRemovalTest do
  @moduledoc """
  Access the site grants can be taken away here, on purpose and on the record.

  The mirror replays Confluence, so a removal is not an edit on the site: the
  row stays, marked as the mirror's refusal, and the next run leaves it alone.
  The dangerous half is the empty case — a space whose readers were all removed
  must read as *closed*, never as *open*, because "no rows" already means
  "everybody" everywhere else in `Authorization`.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import Ecto.Query
  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Page, PageRestriction, SpacePermission}
  alias ConfluencePhxMirror.Repo

  setup do
    %{admin: user_fixture(%{email: "removal.admin@example.com", role: "admin"})}
  end

  describe "a space" do
    setup do
      space = space_fixture(%{key: "REMOVALS"})

      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "group", subject_key: "confluence-users"},
          %{operation: "read", subject_type: "user", subject_key: "reader@example.com"}
        ])

      %{space: space, reader: user_fixture(%{email: "reader@example.com"})}
    end

    test "an identity the site lists can be removed here, and the next run leaves it out", %{
      space: space,
      reader: reader,
      admin: admin
    } do
      assert Authorization.can_read_space?(Scope.for_user(reader), space)

      {:ok, row} = Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, admin})

      assert row.revoked_by_id == admin.id
      refute Authorization.can_read_space?(Scope.for_user(reader), space)

      # What the next run does with the same listing.
      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "group", subject_key: "confluence-users"},
          %{operation: "read", subject_type: "user", subject_key: "reader@example.com"}
        ])

      refute Authorization.can_read_space?(Scope.for_user(reader), space)
      assert [%{subject_key: "reader@example.com"}] = Mirror.space_grants(space).removed
    end

    test "restoring brings the site's reader back without waiting for a run", %{
      space: space,
      reader: reader,
      admin: admin
    } do
      {:ok, _} = Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, admin})
      {:ok, _} = Mirror.restore_space_reader(space, "user", "reader@example.com", {:user, admin})

      assert Authorization.can_read_space?(Scope.for_user(reader), space)
      assert Mirror.space_grants(space).removed == []
      assert Mirror.space_grants(space).users |> Enum.map(& &1.key) == ["reader@example.com"]
    end

    test "removing the last reader closes the space instead of opening it", %{
      space: space,
      admin: admin
    } do
      {:ok, _} = Mirror.remove_space_reader(space, "group", "confluence-users", {:user, admin})
      {:ok, _} = Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, admin})

      outsider = Scope.for_user(user_fixture(%{email: "outsider@example.com"}))

      refute Authorization.can_read_space?(outsider, space)
      refute Authorization.uniform_readership?(outsider)

      # The same answer for a catalog, in one statement rather than one per space.
      assert Authorization.readable_spaces(outsider) == []
      assert space in Authorization.readable_spaces(Scope.for_user(admin))
    end

    test "the space keeps saying it is narrowed, with nobody left to name", %{
      space: space,
      admin: admin
    } do
      {:ok, _} = Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, admin})
      {:ok, _} = Mirror.remove_space_reader(space, "group", "confluence-users", {:user, admin})

      grants = Mirror.space_grants(space)

      assert Mirror.narrowed?(grants)
      refute grants.synced?

      assert grants.removed |> Enum.map(& &1.subject_key) |> Enum.sort() ==
               ["confluence-users", "reader@example.com"]
    end

    test "a space the site opens again drops the removal", %{space: space, admin: admin} do
      {:ok, _} = Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, admin})

      {:ok, _} = Mirror.replace_space_permissions(space, [])

      assert Mirror.space_grants(space).removed == []
      refute Mirror.narrowed?(Mirror.space_grants(space))
    end

    test "only an administrator may remove, and only what the site lists", %{
      space: space,
      reader: reader,
      admin: admin
    } do
      assert {:error, :not_authorized} =
               Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, reader})

      assert {:error, :not_listed} =
               Mirror.remove_space_reader(space, "user", "nobody@example.com", {:user, admin})

      assert {:error, :not_removed} =
               Mirror.restore_space_reader(space, "user", "nobody@example.com", {:user, admin})
    end

    test "a removal is in the audit log, with the identity named", %{space: space, admin: admin} do
      {:ok, _} = Mirror.remove_space_reader(space, "group", "confluence-users", {:user, admin})

      entry = Audit.recent(1) |> hd()
      assert entry.action == "space.access_removed"
      assert entry.entity_id == space.key
      assert entry.metadata["subject"] == "confluence-users"
    end

    test "a grant the site also lists no longer breaks the run", %{space: space, admin: admin} do
      person = a_person_the_site_names("557058:guest-reader", "Guest Reader")
      {:ok, _} = Mirror.grant_space_access(space, "user", person, {:user, admin})

      # The site starts naming the person the mirror already granted.
      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "group", subject_key: "confluence-users"},
          %{operation: "read", subject_type: "user", subject_key: person}
        ])

      assert [%{subject_key: ^person}] = Mirror.space_grants(space).granted
    end

    test "the catalog summary counts readers and removals apart", %{space: space, admin: admin} do
      {:ok, _} = Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, admin})

      assert %{groups: 1, users: 0, anonymous: false, removed: 1} =
               Mirror.space_access_by([space.id])[space.id]
    end
  end

  describe "a page" do
    setup do
      space = space_fixture(%{key: "PAGEREMOVALS"})
      page = page_fixture(space, %{title: "Salaries"})

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"},
          %{operation: "read", subject_type: "user", subject_key: "reader@example.com"}
        ])

      %{space: space, page: page, reader: user_fixture(%{email: "reader@example.com"})}
    end

    test "an identity the site lists can be removed, and a run leaves it out", %{
      page: page,
      reader: reader,
      admin: admin
    } do
      assert Authorization.can_read_page?(Scope.for_user(reader), page)

      {:ok, _} = Mirror.remove_page_reader(page, "user", "reader@example.com", {:user, admin})

      refute Authorization.can_read_page?(Scope.for_user(reader), page)

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"},
          %{operation: "read", subject_type: "user", subject_key: "reader@example.com"}
        ])

      refute Authorization.can_read_page?(Scope.for_user(reader), page)
      assert [%{subject_key: "reader@example.com"}] = Mirror.page_grants(page).removed
    end

    test "removing every reader closes the page rather than opening it", %{
      page: page,
      admin: admin
    } do
      {:ok, _} = Mirror.remove_page_reader(page, "group", "leadership", {:user, admin})
      {:ok, _} = Mirror.remove_page_reader(page, "user", "reader@example.com", {:user, admin})

      stranger = Scope.for_user(user_fixture(%{email: "stranger@example.com"}))

      refute Authorization.can_read_page?(stranger, page)
      assert Authorization.readable_pages(stranger, [page]) == []
    end

    test "a removal survives a run and can still be undone", %{
      page: page,
      reader: reader,
      admin: admin
    } do
      {:ok, _} = Mirror.remove_page_reader(page, "user", "reader@example.com", {:user, admin})

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"},
          %{operation: "read", subject_type: "user", subject_key: "reader@example.com"}
        ])

      {:ok, _} = Mirror.restore_page_reader(page, "user", "reader@example.com", {:user, admin})

      assert Authorization.can_read_page?(Scope.for_user(reader), page)
      assert Mirror.page_grants(page).removed == []
    end

    test "a page the site opens again drops the removal", %{page: page, admin: admin} do
      {:ok, _} = Mirror.remove_page_reader(page, "user", "reader@example.com", {:user, admin})
      {:ok, _} = Mirror.replace_page_restrictions(page, [])

      assert Mirror.page_grants(page).removed == []
      refute Mirror.narrowed?(Mirror.page_grants(page))
    end

    test "the audit log names the page", %{page: page, admin: admin} do
      {:ok, _} = Mirror.remove_page_reader(page, "group", "leadership", {:user, admin})

      entry = Audit.recent(1) |> hd()
      assert entry.action == "page.access_removed"
      assert entry.entity_id == page.title
    end
  end

  describe "when the mirror lets go of the content" do
    test "a trashed page takes the mirror's own decisions with it", %{admin: admin} do
      space = space_fixture(%{key: "TRASHPERMS"})
      page = page_fixture(space, %{title: "Contract"})

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"},
          %{operation: "read", subject_type: "user", subject_key: "reader@example.com"}
        ])

      {:ok, _} = Mirror.remove_page_reader(page, "group", "leadership", {:user, admin})

      assert 1 = Mirror.trash_absent_pages([page])

      # The site's row stays for the audit trail; ours is gone.
      assert page_rows(page) == [{:synced, "user", "reader@example.com"}]
    end

    test "a trashed space takes its own decisions, and its pages', with it", %{admin: admin} do
      space = space_fixture(%{key: "TRASHSPACE"})
      page = page_fixture(space, %{title: "Handbook"})
      person = a_person_the_site_names("557058:page-guest", "Page Guest")

      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "group", subject_key: "confluence-users"},
          %{operation: "read", subject_type: "user", subject_key: "reader@example.com"}
        ])

      {:ok, _} =
        Mirror.replace_page_restrictions(page, [
          %{operation: "read", subject_type: "group", subject_key: "leadership"}
        ])

      {:ok, _} = Mirror.remove_space_reader(space, "user", "reader@example.com", {:user, admin})
      {:ok, _} = Mirror.grant_page_access(page, "user", person, {:user, admin})

      Mirror.trash_space(space)

      assert space_rows(space) == [{:synced, "group", "confluence-users"}]
      assert page_rows(page) == [{:synced, "group", "leadership"}]
    end
  end

  # A person the mirror can vouch for: somebody the content names. A grant
  # refuses an identity the mirror has never seen.
  defp a_person_the_site_names(account_id, name) do
    page_fixture(space_fixture(), %{author_name: name, author_account_id: account_id})
    account_id
  end

  defp space_rows(space) do
    from(p in SpacePermission,
      where: p.space_id == ^space.id,
      select: {p.subject_type, p.subject_key, p.granted_by_id, p.revoked_by_id},
      order_by: [asc: p.subject_key]
    )
    |> Repo.all()
    |> Enum.map(&kind/1)
  end

  defp page_rows(page) do
    from(r in PageRestriction,
      join: p in Page,
      on: p.id == r.page_id,
      where: r.page_id == ^page.id,
      select: {r.subject_type, r.subject_key, r.granted_by_id, r.revoked_by_id},
      order_by: [asc: r.subject_key]
    )
    |> Repo.all()
    |> Enum.map(&kind/1)
  end

  defp kind({type, key, nil, nil}), do: {:synced, type, key}
  defp kind({type, key, _granted, _revoked}), do: {:overlay, type, key}
end
