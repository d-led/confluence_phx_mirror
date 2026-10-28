defmodule ConfluencePhxMirror.Sync.DynamicContent.ContributorsTest do
  @moduledoc """
  *Contributors* counts one author per page, because one author per page is what
  a sync can read.

  Three claims are pinned: the list is the port's answer and nothing invented, a
  deployment that publishes no names offers none, and a space the port will not
  scan says so rather than counting half of it.
  """

  use ExUnit.Case, async: true

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
end
