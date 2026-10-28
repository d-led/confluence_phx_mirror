defmodule ConfluencePhxMirror.Sync.DynamicContent.SourceMirrorTest do
  @moduledoc """
  The port over the mirror's own database, where the audience rule is applied.

  `page_by_title/2` is the answer an including macro cannot do without, and the
  only one with a syntax: Confluence writes a page in another space as
  `KEY/Page Title`. Both forms are checked against the rule that a macro baked
  into a page may only name a page at least as wide as it is.
  """

  use ConfluencePhxMirror.DataCase, async: true

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Sync.DynamicContent.Source

  test "a title is looked up in the host's own space" do
    docs = space_fixture(%{key: "DOCS", name: "Docs"})
    host = page_fixture(docs, %{title: "Home", confluence_id: 97_110})
    neighbour = page_fixture(docs, %{title: "Install", confluence_id: 97_111})

    assert {:ok, found} = Source.Mirror.page_by_title(host, "Install")
    assert found.id == neighbour.id
  end

  test "a title written as KEY/Title is looked up in that space" do
    docs = space_fixture(%{key: "DOCS", name: "Docs"})
    ops = space_fixture(%{key: "OPS", name: "Ops"})
    host = page_fixture(docs, %{title: "Home", confluence_id: 97_112})
    runbooks = page_fixture(ops, %{title: "Runbooks", confluence_id: 97_113})

    assert {:ok, found} = Source.Mirror.page_by_title(host, "OPS/Runbooks")
    assert found.id == runbooks.id
  end

  test "a title that merely contains a slash stays a title" do
    docs = space_fixture(%{key: "DOCS", name: "Docs"})
    host = page_fixture(docs, %{title: "Home", confluence_id: 97_114})
    slashed = page_fixture(docs, %{title: "A/B testing", confluence_id: 97_115})

    assert {:ok, found} = Source.Mirror.page_by_title(host, "A/B testing")
    assert found.id == slashed.id
  end

  test "a page nobody has is :error, not an empty answer" do
    docs = space_fixture(%{key: "DOCS", name: "Docs"})
    host = page_fixture(docs, %{title: "Home", confluence_id: 97_116})

    assert Source.Mirror.page_by_title(host, "Missing") == :error
  end

  test "a page narrower than the host is :error, whatever its title" do
    # An include is baked into the host for everybody who may read the host, so
    # an open page may not pull in a page behind a group.
    docs = space_fixture(%{key: "DOCS", name: "Docs"})
    ops = space_fixture(%{key: "OPS", name: "Ops"})

    {:ok, _} =
      Mirror.replace_space_permissions(ops, [
        %{operation: "read", subject_type: "group", subject_key: "ops-team"}
      ])

    host = page_fixture(docs, %{title: "Home", confluence_id: 97_117})
    page_fixture(ops, %{title: "Runbooks", confluence_id: 97_118})

    assert Source.Mirror.page_by_title(host, "OPS/Runbooks") == :error
  end
end
