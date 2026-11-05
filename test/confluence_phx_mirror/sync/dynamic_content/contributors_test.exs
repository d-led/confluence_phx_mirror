defmodule ConfluencePhxMirror.Sync.DynamicContent.ContributorsTest do
  @moduledoc """
  *Contributors* counts one author per page, because one author per page is what
  a sync can read.

  Three claims are pinned: the list is the port's answer and nothing invented, a
  deployment that publishes no names offers none, and a space the port will not
  scan says so rather than counting half of it.
  """

  # Sequential: a "deployment that publishes no names" is the application
  # environment, which every test in the suite shares — see `TestConfig`.
  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent
  alias ConfluencePhxMirror.TestConfig

  @marker ~s(<div class="mirror-macro" data-macro="contributors"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  setup do
    StubContent.script(
      contributors:
        {:ok,
         [
           %{name: "Jane Doe", account_id: "acc-1", pages: 12},
           %{name: "Sam Rivera", account_id: "acc-2", pages: 1}
         ]}
    )
  end

  test "lists the people the port counted, with what each of them wrote" do
    html = expand()

    assert text(html) =~ "Contributors"
    assert names(html) == ["Jane Doe · 12 pages", "Sam Rivera · 1 page"]
  end

  # The rows carry the account id, and `/people/:account_id` is that person's
  # page here — a list of names that nothing can be clicked is a dead end for a
  # reader who wants to know who wrote the space.
  test "each name leads to that person's page here" do
    assert hrefs(expand()) == ["/people/acc-1", "/people/acc-2"]
  end

  test "a name the site gave no account stays a word, not a broken link" do
    StubContent.script(contributors: {:ok, [%{name: "Anon", account_id: nil, pages: 3}]})

    html = expand()

    assert hrefs(html) == []
    assert text(html) =~ "Anon · 3 pages"
  end

  test "asks about the space the marker names, ten people at most" do
    expand()
    assert StubContent.questions() == [{:contributors, nil}]

    StubContent.script(contributors: {:ok, []})

    expand(
      ~s(<div class="mirror-macro" data-macro="contributors" data-space="OPS" data-limit="3"></div>)
    )

    assert StubContent.questions() == [{:contributors, "OPS"}]
  end

  test "a deployment that publishes no names shows no contributors" do
    TestConfig.put(:anonymize_contributors, true)

    assert text(expand()) == "This mirror does not publish its contributors."
  end

  # One body is rendered at sync time and served to every reader, so a space a
  # stranger may open has to be stored in the stranger's shape — there is no
  # second copy to anonymise later.
  test "a public space's body names nobody, whatever the reader" do
    TestConfig.put(:public_spaces, ["ENG"])

    html = expand()

    assert text(html) == "This mirror does not publish its contributors."
    assert hrefs(html) == []
  end

  test "a space off the public list keeps its names" do
    TestConfig.put(:public_spaces, ["OPS"])

    assert names(expand()) == ["Jane Doe · 12 pages", "Sam Rivera · 1 page"]
  end

  test "a space too large to count says so instead of counting half of it" do
    StubContent.script(contributors: {:error, :too_large})

    assert text(expand()) =~ "too large to count its contributors"
  end

  test "a space where nobody is named says that" do
    StubContent.script(contributors: {:ok, []})

    assert text(expand()) == "No page in this space names an author yet."
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp names(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("ul.mirror-dynamic-list li")
    |> Enum.map(&(&1 |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp hrefs(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("ul.mirror-dynamic-list li a")
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end
end
