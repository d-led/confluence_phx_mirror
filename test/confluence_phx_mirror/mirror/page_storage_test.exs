defmodule ConfluencePhxMirror.Mirror.PageStorageTest do
  @moduledoc """
  What a page row holds, in the one place the two stores could disagree: the URL
  segment whose value is "nothing".
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Repo

  test "a title with nothing ASCII in it is stored with an empty segment" do
    space = space_fixture(%{key: "MFS"})
    title = "Обзор проекта"

    assert {:ok, page} = Mirror.upsert_page(space, page_attrs(title))

    # Written, not left out: a store is free to declare the column required, and
    # one does. `""` and `nil` are the same page to the URLs, so the value the
    # ingest computes is what goes in.
    assert page.slug == ""
    assert Repo.get_by!(Page, confluence_id: 4_242).slug == ""
  end

  test "a title with ASCII in it keeps the segment Confluence would give it" do
    space = space_fixture(%{key: "MFS"})

    assert {:ok, page} = Mirror.upsert_page(space, page_attrs("API /v2: changelog #2"))

    assert page.slug == "API+v2+changelog+2"
  end

  defp page_attrs(title) do
    %{
      confluence_id: 4_242,
      title: title,
      slug: Page.slugify(title),
      author_name: "Jane Doe",
      external_updated_at: ~U[2026-10-01 12:00:00Z]
    }
  end
end
