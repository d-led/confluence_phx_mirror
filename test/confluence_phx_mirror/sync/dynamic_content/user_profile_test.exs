defmodule ConfluencePhxMirror.Sync.DynamicContent.UserProfileTest do
  @moduledoc """
  *User profile* is one person, and the pages of theirs this page's readers may
  open.

  Confluence resolves it in the reader's browser and leaves the macro unexpanded,
  so a page carrying it showed the unknown-macro widget. What the macro names is
  a Confluence account id, and the mirror learns those from the bylines it has
  read — which is why the answer is a person and not a profile form.
  """

  use ExUnit.Case, async: false

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent
  alias ConfluencePhxMirror.TestConfig

  @account "557058:12861f68-8857-4349-927d-e49dfb30bd52"
  @marker ~s(<div class="mirror-macro" data-macro="user-profile" data-user="#{@account}"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Engineering", space: @space}

  setup do
    StubContent.script(authored: {:ok, %{name: "Jane Doe", pages: [page(1002, "Architecture")]}})
  end

  test "names the person and links to their page in the people directory" do
    html = expand()

    assert html =~ "Jane Doe"
    assert hrefs(html) == ["/people/#{"557058%3A12861f68-8857-4349-927d-e49dfb30bd52"}"]
  end

  # The body is rendered once, at sync time, for every reader: a space a
  # stranger may open is stored without the name or the link.
  test "a page in a public space names nobody" do
    TestConfig.put(:public_spaces, ["ENG"])

    html = expand()

    refute html =~ "Jane Doe"
    assert hrefs(html) == []
  end

  test "lists the pages of theirs these readers may open" do
    assert titled(expand()) == ["Architecture"]
  end

  test "asks the port about the account the marker names" do
    expand()

    assert StubContent.questions() == [{:authored, @account}]
  end

  test "a person whose pages are all out of these readers' reach says so" do
    StubContent.script(authored: {:ok, %{name: "Jane Doe", pages: []}})

    assert expand() =~ "No page these readers may open is written by Jane Doe."
  end

  test "a person the mirror has never seen is not invented" do
    StubContent.script(authored: :error)

    assert expand() =~ "not in the mirror, or not readable here"
  end

  test "a marker that names nobody says so instead of guessing" do
    assert expand(~s(<div class="mirror-macro" data-macro="user-profile"></div>)) =~
             "names no person"
  end

  test "the editor's own spelling of the macro draws the same profile" do
    # The editor writes `profile`; the seeded page carried `user-profile`.
    html =
      expand(~s(<div class="mirror-macro" data-macro="profile" data-user="#{@account}"></div>))

    assert html =~ "Jane Doe"
    assert titled(html) == ["Architecture"]
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp hrefs(html) do
    html
    |> document()
    |> Floki.find("a.mirror-person-link")
    |> Enum.map(&Floki.attribute(&1, "href"))
    |> List.flatten()
  end

  defp titled(html),
    do: html |> document() |> Floki.find("ul.mirror-dynamic-list a") |> Enum.map(&Floki.text/1)

  defp document(html), do: Floki.parse_fragment!(html)

  defp page(id, title) do
    %{
      id: id,
      confluence_id: id,
      title: title,
      slug: String.downcase(String.replace(title, " ", "-")),
      space: @space,
      external_updated_at: ~U[2026-10-01 12:00:00Z]
    }
  end
end
