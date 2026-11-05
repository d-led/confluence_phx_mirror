defmodule ConfluencePhxMirror.AuthorizationTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Ecto.Query, only: [from: 2]

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.TestConfig

  setup do
    demo_snapshot!()
    :ok
  end

  test "an open space is readable without signing in" do
    space = Mirror.get_space_by_key("ENG")

    assert Authorization.can_read_space?(anonymous(), space)
  end

  test "a page restricted to a group is hidden from readers outside it" do
    page = Mirror.get_page!(1003)

    refute Authorization.can_read_page?(anonymous(), page)
    refute Authorization.can_read_page?(reader("someone@example.com"), page)
    assert Authorization.can_read_page?(reader("insider@example.com", ["confluence-users"]), page)
  end

  test "a space restricted to signed-in users hides itself from anonymous readers" do
    space = Mirror.get_space_by_key("PROD")

    refute Authorization.can_read_space?(anonymous(), space)
    assert Authorization.can_read_space?(reader("reader@example.com"), space)
  end

  test "restricting a page by account id matches the same reader" do
    page = Mirror.get_page!(1002)

    {:ok, _} =
      Mirror.replace_page_restrictions(page, [%{subject_type: "user", subject_key: "acc-42"}])

    refute Authorization.can_read_page?(reader("someone@example.com"), page)

    reader = reader("someone@example.com")

    {:ok, user} =
      reader.user |> User.identity_changeset(%{confluence_account_id: "acc-42"}) |> Repo.update()

    assert Authorization.can_read_page?(Scope.for_user(user), page)
  end

  test "mirror administrators see everything" do
    admin = user_fixture(%{email: "admin@confluence-mirror.test", role: "admin"})
    scope = Scope.for_user(admin)

    assert Authorization.can_read_page?(scope, Mirror.get_page!(1003))
    assert Authorization.can_read_space?(scope, Mirror.get_space_by_key("PROD"))
  end

  test "the sync stores the permissions it read" do
    assert [{:synced, "group", "confluence-users"}] = Mirror.page_restrictions(1003) |> kinds()

    refute Mirror.space_permissions(Mirror.get_space_by_key("PROD").id) == []
    assert Mirror.space_permissions(Mirror.get_space_by_key("ENG").id) == []
  end

  test "a reader who is in the group according to Confluence may read the page" do
    page = Mirror.get_page!(1003)
    outsider = "late-joiner@demo.atlassian.net"

    refute Authorization.can_read_page?(reader(outsider), page)

    {:ok, _} =
      Mirror.replace_group_members("confluence-users", [
        %{email: outsider, display_name: "Late Joiner"}
      ])

    assert Authorization.can_read_page?(reader(outsider), page)
  end

  describe "a public site" do
    # A mirror put on the internet cannot read silence in its own permission
    # tables as "everyone": a read that failed, or a space the sync never
    # stored, is indistinguishable from it. ENG has no permission rows at all.
    setup do
      TestConfig.put(:public_site, true)
      :ok
    end

    test "a space whose permissions were never stored is not open to a stranger" do
      eng = Mirror.get_space_by_key("ENG")

      refute Authorization.can_read_space?(anonymous(), eng)
      refute Enum.any?(Authorization.readable_spaces(anonymous()), &(&1.key == "ENG"))
    end

    test "its pages are not open either, whichever way the question is asked" do
      refute Authorization.can_read_page?(anonymous(), Mirror.get_page!(1002))

      ids = from(p in Page, as: :page, where: p.confluence_id == 1002, select: p.confluence_id)

      assert Repo.all(Authorization.restrict_pages(ids, anonymous())) == []
    end

    test "a reader with an account keeps the mirror's own reading of it" do
      assert Authorization.can_read_space?(
               reader("someone@example.com"),
               Mirror.get_space_by_key("ENG")
             )
    end

    test "a stranger reads what the site marks anonymous" do
      space = space_fixture(%{key: "PUB", name: "Published"})

      {:ok, _} =
        Mirror.replace_space_permissions(space, [
          %{operation: "read", subject_type: "anonymous", subject_key: nil}
        ])

      assert Authorization.can_read_space?(anonymous(), space)
      assert Authorization.can_read_space?(reader("someone@example.com"), space)
    end
  end

  describe "a public subset of the spaces" do
    # Two spaces the site marks anonymous, so the only thing between a stranger
    # and the second one is the list.
    setup do
      TestConfig.put(:public_site, true)
      TestConfig.put(:public_spaces, ["openbook"])

      spaces =
        for key <- ~w(OPENBOOK SECRET) do
          space = space_fixture(%{key: key, name: "Space #{key}"})

          {:ok, _} =
            Mirror.replace_space_permissions(space, [
              %{operation: "read", subject_type: "anonymous", subject_key: nil}
            ])

          space
        end

      [open, secret] = spaces

      %{
        open: open,
        secret: secret,
        open_page: page_fixture(open, %{confluence_id: 91_101, title: "Runbook"}),
        secret_page: page_fixture(secret, %{confluence_id: 91_102, title: "Salaries"})
      }
    end

    test "a stranger reads the listed space", %{open: open, open_page: page} do
      assert Authorization.can_read_space?(anonymous(), open)
      assert Authorization.can_read_page?(anonymous(), page)
    end

    test "and not the one beside it, however open its permissions", %{
      secret: secret,
      secret_page: page
    } do
      refute Authorization.can_read_space?(anonymous(), secret)
      refute Authorization.can_read_page?(anonymous(), page)
      assert Authorization.readable_pages(anonymous(), [page]) == []
    end

    test "the catalogue and the sidebar agree with the predicate", %{
      open_page: open_page,
      secret_page: secret_page
    } do
      keys = Enum.map(Authorization.readable_spaces(anonymous()), & &1.key)

      assert "OPENBOOK" in keys
      refute "SECRET" in keys

      ids =
        from(p in Page,
          as: :page,
          where: p.confluence_id in ^[open_page.confluence_id, secret_page.confluence_id],
          select: p.confluence_id
        )

      assert Repo.all(Authorization.restrict_pages(ids, anonymous())) == [open_page.confluence_id]
    end

    test "the same pages are still there for a reader with an account", %{
      secret_page: page
    } do
      assert Authorization.can_read_page?(reader("someone@example.com"), page)
    end
  end

  describe "a personal space" do
    setup do
      personal =
        space_fixture(%{key: "~557058ABCDEF", name: "Space Owner", type: "personal"})

      draft = page_fixture(personal, %{confluence_id: 9001, title: "My draft"})
      %{personal: personal, draft: draft}
    end

    test "belongs to the account its key names, whoever else asks", %{personal: personal} do
      assert Authorization.can_read_space?(owner(), personal)
      refute Authorization.can_read_space?(reader("someone@example.com"), personal)
      refute Authorization.can_read_space?(anonymous(), personal)
    end

    test "is offered to its owner alone", %{personal: personal} do
      assert personal in Authorization.readable_spaces(owner())
      refute personal in Authorization.readable_spaces(reader("someone@example.com"))
    end

    test "keeps its pages, which carry no permission of their own", %{
      personal: personal,
      draft: draft
    } do
      # The space has no permission rows, so without the ownership rule its pages
      # would be as open as any other space's.
      outsider = reader("someone@example.com")

      refute Authorization.can_read_page?(outsider, draft)
      assert Authorization.readable_pages(outsider, [draft]) == []
      assert Authorization.readable_pages(owner(), [draft]) == [draft]

      drafts =
        from(p in Page, as: :page, where: p.space_id == ^personal.id, select: p.confluence_id)

      assert Repo.all(Authorization.restrict_pages(drafts, outsider)) == []
      assert Repo.all(Authorization.restrict_pages(drafts, owner())) == [9001]
    end

    test "is never listed on a page open to more people", %{personal: personal, draft: draft} do
      open = Mirror.get_page!(1002)
      sibling = page_fixture(personal, %{confluence_id: 9002, title: "My other draft"})

      assert Authorization.readable_alongside(open, [draft]) == []
      assert Authorization.readable_alongside(draft, [sibling]) == [sibling]
    end

    test "is still there for an administrator", %{personal: personal, draft: draft} do
      admin = user_fixture(%{email: "admin@confluence-mirror.test", role: "admin"})
      scope = Scope.for_user(admin)

      assert Authorization.can_read_space?(scope, personal)
      assert Authorization.can_read_page?(scope, draft)
    end
  end

  defp anonymous, do: Scope.for_user(nil)

  # What a screen reads a permission row as: the site's, or one the mirror
  # decided here.
  defp kinds(rows) do
    Enum.map(rows, fn row ->
      if is_nil(row.granted_by_id) and is_nil(row.revoked_by_id),
        do: {:synced, row.subject_type, row.subject_key},
        else: {:overlay, row.subject_type, row.subject_key}
    end)
  end

  # The account the personal key names, signed in. Confluence hands out account
  # ids in lower case and the space key keeps the case it was stored with.
  defp owner do
    user = user_fixture(%{email: "owner@demo.atlassian.net"})

    {:ok, user} =
      user
      |> User.identity_changeset(%{confluence_account_id: "557058abcdef"})
      |> Repo.update()

    Scope.for_user(user)
  end

  defp reader(email, groups \\ []) do
    user = user_fixture(%{email: email})

    {:ok, user} =
      user
      |> User.identity_changeset(%{groups: groups})
      |> Repo.update()

    Scope.for_user(user)
  end
end
