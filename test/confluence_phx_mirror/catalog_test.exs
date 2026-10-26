defmodule ConfluencePhxMirror.CatalogTest do
  @moduledoc """
  What a catalog returns for a given filter: which entries match, in what order,
  and one page at a time.

  Each test builds only the rows it talks about, so it reads as a statement
  about filtering rather than as a description of the demo snapshot.
  """

  use ConfluencePhxMirror.DataCase, async: true

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Authorization
  alias ConfluencePhxMirror.Catalog
  alias ConfluencePhxMirror.Mirror

  describe "what a reader types" do
    test "is split into one token per word, whatever the case and spacing" do
      assert Catalog.tokens("  Arch   ENG  eng ") == ["arch", "eng"]
    end

    test "asks for everything when the reader has typed nothing yet" do
      assert Catalog.tokens(nil) == []
      assert Catalog.tokens("   ") == []
    end

    test "treats a wildcard as an ordinary character" do
      space_fixture(%{name: "Operations", description: "Runs at 100% capacity."})
      space_fixture(%{name: "Product Hub", description: "Plans and releases."})

      assert keys(Catalog.spaces(reader())) == ["Operations", "Product Hub"]
      assert keys(Catalog.spaces(reader(), q: "%")) == ["Operations"]
    end
  end

  describe "the space directory" do
    test "matches the name, the key and the description" do
      space_fixture(%{key: "ENG", name: "Engineering Handbook", description: "How we build."})
      space_fixture(%{key: "PROD", name: "Product Hub", description: "Roadmap and releases."})

      assert keys(Catalog.spaces(reader(), q: "handbook")) == ["Engineering Handbook"]
      assert keys(Catalog.spaces(reader(), q: "prod")) == ["Product Hub"]
      assert keys(Catalog.spaces(reader(), q: "ROADMAP")) == ["Product Hub"]
    end

    test "needs every word the reader typed to appear" do
      space_fixture(%{name: "Engineering Handbook"})
      space_fixture(%{name: "Product Hub"})

      assert keys(Catalog.spaces(reader(), q: "engineering handbook")) == ["Engineering Handbook"]
      assert Catalog.spaces(reader(), q: "engineering product").items == []
    end

    test "counts pages and blog posts apart" do
      space = space_fixture(%{name: "Product Hub"})
      page_fixture(space)
      page_fixture(space)
      page_fixture(space, %{type: "blogpost"})

      assert [%{pages: 2, blog_posts: 1}] = Catalog.spaces(reader()).items
    end

    test "shows a reader only the spaces they may open" do
      open_space()
      private_space()

      assert keys(Catalog.spaces(anonymous())) == ["Open space"]
      assert keys(Catalog.spaces(reader())) == ["Open space"]

      assert keys(Catalog.spaces(reader("member@example.com", ["product-team"]))) ==
               ["Open space", "Private space"]

      assert keys(Catalog.spaces(admin())) == ["Open space", "Private space"]
    end

    test "agrees with the one-space-at-a-time permission check" do
      open_space()
      private_space()

      spaces = Mirror.list_spaces()

      scopes = [
        anonymous(),
        reader(),
        reader("member@example.com", ["product-team"]),
        admin()
      ]

      for scope <- scopes do
        readable =
          spaces
          |> Enum.filter(&Authorization.can_read_space?(scope, &1))
          |> Enum.map(& &1.name)

        assert keys(Catalog.spaces(scope)) == readable
      end
    end

    test "reads one page at a time, telling whether there is more" do
      for name <- ["Catalog Alpha", "Catalog Beta", "Catalog Gamma"] do
        space_fixture(%{name: name})
      end

      first = Catalog.spaces(reader(), q: "catalog", limit: 2)
      second = Catalog.spaces(reader(), q: "catalog", limit: 2, offset: 2)

      assert keys(first) == ["Catalog Alpha", "Catalog Beta"]
      assert first.more?

      assert keys(second) == ["Catalog Gamma"]
      refute second.more?
    end
  end

  describe "the people directory" do
    test "finds authors by name, with how much they wrote" do
      space = space_fixture()
      page_fixture(space, %{author_name: "Jane Doe"})
      page_fixture(space, %{author_name: "Jane Doe"})
      page_fixture(space, %{author_name: "Sam Rivera"})

      assert [%{name: "Jane Doe", pages: 2}] = Catalog.people(reader(), q: "jane").items
    end

    test "needs every word the reader typed to appear" do
      space = space_fixture()
      page_fixture(space, %{author_name: "Jane Doe"})
      page_fixture(space, %{author_name: "Sam Rivera"})

      assert Catalog.people(reader(), q: "jane rivera").items == []
    end

    test "counts only what the reader may open" do
      space = space_fixture()
      page_fixture(space, %{author_name: "Jane Doe"})
      restricted_page(space, %{author_name: "Jane Doe"})

      assert [%{name: "Jane Doe", pages: 1}] = Catalog.people(reader()).items
      assert [%{name: "Jane Doe", pages: 1}] = Catalog.people(outsider()).items
      assert [%{name: "Jane Doe", pages: 2}] = Catalog.people(insider()).items
      assert [%{name: "Jane Doe", pages: 2}] = Catalog.people(admin()).items
    end
  end

  describe "the label index" do
    test "finds labels by name, with how many pages carry them" do
      space = space_fixture()
      label_fixture(page_fixture(space), ["release", "announcement"])
      label_fixture(page_fixture(space), ["release"])

      assert [%{name: "release", pages: 2}] = Catalog.labels(reader(), q: "release").items
    end

    test "counts only what the reader may open" do
      space = space_fixture()
      label_fixture(page_fixture(space), ["release", "shared"])
      label_fixture(restricted_page(space), ["release", "internal"])

      assert labels(reader()) == %{"release" => 1, "shared" => 1}
      assert labels(outsider()) == %{"release" => 1, "shared" => 1}

      assert labels(insider()) == %{"internal" => 1, "release" => 2, "shared" => 1}
      assert labels(admin()) == %{"internal" => 1, "release" => 2, "shared" => 1}
    end

    test "a label only on restricted pages does not appear at all" do
      space = space_fixture()
      label_fixture(restricted_page(space), ["internal"])

      assert Catalog.labels(reader()).items == []
    end
  end

  describe "a space's content" do
    test "finds pages by title or by author" do
      space = space_fixture()
      page_fixture(space, %{title: "Architecture Overview", author_name: "Jane Doe"})
      page_fixture(space, %{title: "Roadmap", author_name: "Sam Rivera"})

      assert titles(Catalog.contents(space, q: "architecture")) == ["Architecture Overview"]
      assert titles(Catalog.contents(space, q: "jane")) == ["Architecture Overview"]
    end

    test "keeps archived pages, because they stay readable" do
      space = space_fixture()
      page_fixture(space, %{title: "Deprecated Setup", status: "archived"})

      assert titles(Catalog.contents(space)) == ["Deprecated Setup"]
    end

    test "separates blog posts from pages and orders them newest first" do
      space = space_fixture()
      page_fixture(space, %{title: "Home"})

      page_fixture(space, %{
        title: "Release 1.0",
        type: "blogpost",
        external_updated_at: ~U[2026-09-01 00:00:00Z]
      })

      page_fixture(space, %{
        title: "Release 2.0",
        type: "blogpost",
        external_updated_at: ~U[2026-10-01 00:00:00Z]
      })

      assert titles(Catalog.contents(space, type: "blogpost", sort: :recent)) ==
               ["Release 2.0", "Release 1.0"]
    end

    test "never shows another space's content" do
      ours = space_fixture()
      theirs = space_fixture()
      page_fixture(ours, %{title: "Ours"})
      page_fixture(theirs, %{title: "Theirs"})

      assert titles(Catalog.contents(ours)) == ["Ours"]
    end

    test "reads one page at a time, never repeating a row" do
      space = space_fixture()
      for title <- ["Alpha", "Beta", "Gamma"], do: page_fixture(space, %{title: title})

      first = Catalog.contents(space, limit: 2)
      second = Catalog.contents(space, limit: 2, offset: 2)

      assert titles(first) == ["Alpha", "Beta"]
      assert titles(second) == ["Gamma"]
      assert first.more?
      refute second.more?
    end
  end

  describe "a space's attachments" do
    test "finds a file by its name or by the page it hangs off" do
      space = space_fixture()
      page = page_fixture(space, %{title: "Architecture Overview"})
      attachment_fixture(page, %{filename: "architecture.csv"})
      attachment_fixture(page, %{filename: "diagram.svg"})

      assert filenames(Catalog.attachments(space, q: "architecture.csv")) == ["architecture.csv"]

      assert filenames(Catalog.attachments(space, q: "architecture overview")) ==
               ["architecture.csv", "diagram.svg"]
    end
  end

  defp keys(%{items: items}), do: Enum.map(items, & &1.space.name)
  defp titles(%{items: items}), do: Enum.map(items, & &1.title)
  defp filenames(%{items: items}), do: Enum.map(items, & &1.filename)

  defp labels(scope), do: Map.new(Catalog.label_counts(scope), &{&1.name, &1.pages})

  defp label_fixture(page, names), do: Mirror.replace_labels(page, names)

  defp open_space, do: space_fixture(%{name: "Open space"})

  # A page only `insider/0` may open: it is restricted to the `engineers` group.
  defp restricted_page(space, attrs \\ %{}) do
    page = page_fixture(space, attrs)

    {:ok, _} =
      Mirror.replace_page_restrictions(page, [
        %{operation: "read", subject_type: "group", subject_key: "engineers"}
      ])

    page
  end

  defp private_space do
    space = space_fixture(%{name: "Private space"})

    {:ok, _} =
      Mirror.replace_space_permissions(space, [
        %{operation: "read", subject_type: "group", subject_key: "product-team"}
      ])

    space
  end

  defp reader(email \\ "reader@example.com", groups \\ []) do
    user = user_fixture(%{email: email})

    {:ok, user} = user |> User.identity_changeset(%{groups: groups}) |> Repo.update()
    Scope.for_user(user)
  end

  defp anonymous, do: Scope.for_user(nil)

  defp admin, do: Scope.for_user(user_fixture(%{email: "admin@example.com", role: "admin"}))

  defp outsider, do: reader("outsider@example.com")

  defp insider, do: reader("insider@example.com", ["engineers"])
end
