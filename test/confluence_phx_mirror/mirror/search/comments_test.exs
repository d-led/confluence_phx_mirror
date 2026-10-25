defmodule ConfluencePhxMirror.Mirror.Search.CommentsTest do
  @moduledoc """
  Comments are content a reader searches: a page is a hit when its comment says
  the words, and the hit says whose comment did.

  The demo snapshot is only mirrored where a case is about it: pages whose text
  happens to contain a fragment would otherwise fill the result window before a
  fixture's page was reached.
  """
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror.Search
  alias ConfluencePhxMirror.Repo

  setup context do
    if context[:demo], do: demo_snapshot!()
    :ok
  end

  defp hit(results, title), do: Enum.find(results, &(&1.page.title == title))

  @tag :demo
  test "a page is found through the words of its comment" do
    # "checklist" is in Sam Rivera's comment on Getting Started and nowhere else
    # in the demo: the page itself does not say it.
    {:ok, results} = Search.text("checklist")
    getting_started = hit(results, "Getting Started")

    assert getting_started.comment.author_name == "Sam Rivera"
    assert getting_started.snippet =~ "Nice checklist"
  end

  @tag :demo
  test "the page's own words win over a comment on the same page" do
    {:ok, results} = Search.text("poll")

    assert %{comment: nil} = hit(results, "Architecture Overview")
  end

  @tag :demo
  test "one page is one result, even when page and comment both match" do
    {:ok, results} = Search.text("checklist")

    assert Enum.count(results, &(&1.page.title == "Getting Started")) == 1
  end

  test "a deleted comment is not searched" do
    space = space_fixture(%{key: "CMTD", name: "Deleted comments"})
    page = page_fixture(space, %{title: "Quiet page", search_text: "quiet"})

    comment = comment_fixture(page, %{body_text: "obsolete wording"})
    deleted_at = DateTime.utc_now() |> DateTime.truncate(:second)
    Repo.update!(Ecto.Changeset.change(comment, deleted_at: deleted_at))

    {:ok, results} = Search.text("obsolete")

    assert hit(results, "Quiet page") == nil
  end

  @tag :demo
  test "a space filter keeps a page found through a comment only inside that space" do
    assert {:ok, inside, _} = Search.structured(%{"q" => "checklist", "space" => "ENG"})
    assert hit(inside, "Getting Started")

    assert {:ok, outside, _} = Search.structured(%{"q" => "checklist", "space" => "PROD"})
    assert hit(outside, "Getting Started") == nil
  end

  @tag :demo
  test "CQL text search reads comments too" do
    {:ok, results} = Search.search(~s(text ~ "checklist"))
    getting_started = hit(results, "Getting Started")

    assert getting_started.comment.author_name == "Sam Rivera"
    assert getting_started.snippet =~ "Nice checklist"
  end
end
