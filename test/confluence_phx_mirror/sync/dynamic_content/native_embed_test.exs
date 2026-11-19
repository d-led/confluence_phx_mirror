defmodule ConfluencePhxMirror.Sync.DynamicContent.NativeEmbedTest do
  @moduledoc """
  *Whiteboards, Databases and Slides*: a board is drawn from its document, and
  anything the mirror cannot read is answered with an apology and a link.

  Confluence's export view carries an unknown-macro placeholder for all three, so
  the document (whiteboard) or the record (database, slides) is all there is to
  go on. A deck has no document at all, so its record's title is the most the
  page can honestly say.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @space %{key: "MFS"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Macros Gallery", space: @space}
  @board "https://dled.atlassian.net/wiki/spaces/MFS/whiteboard/28344336"
  @slides "https://dled.atlassian.net/wiki/spaces/MFS/slides/29163538"

  test "a whiteboard is drawn from its document" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ ~s(class="mirror-whiteboard")
    assert html =~ ~s(href="#{@board}")
    assert drawn_words(html) =~ "January"
  end

  test "the link under a drawing is a caption, not the address itself" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ "<figcaption"
    assert html =~ ~s(href="#{@board}")
    assert html =~ "Whiteboard in Confluence"
    refute html =~ ">#{@board}<"
  end

  test "the drawing opens over the page as a control, and a saved copy knows its board" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ "data-whiteboard-zoom"
    assert html =~ ~s(data-whiteboard-name="whiteboard-28344336.svg")
    assert html =~ ~s(aria-label="Open the whiteboard full screen")
  end

  test "a board the mirror cannot read apologises and points at the original" do
    StubContent.script(whiteboard: {:error, :not_found})

    html = expand(marker("native-embed:whiteboard", @board))

    assert html =~ "could not draw this whiteboard"
    assert html =~ ~s(href="#{@board}")
    refute html =~ "data:image/svg+xml"
  end

  test "a document version this mirror does not know apologises too" do
    StubContent.script(whiteboard: {:ok, %{document("January") | "version" => "2030-01-01"}})

    assert expand(marker("native-embed:whiteboard", @board)) =~ "could not draw this whiteboard"
  end

  test "a database is named and linked, since a view cannot be a still" do
    StubContent.script(whiteboard: {:ok, document("January")})

    html = expand(marker("native-embed:database", @board))

    assert html =~ "Database"
    assert html =~ ~s(href="#{@board}")
    refute html =~ "data:image/svg+xml"
  end

  test "a database is named from its own record, not guessed at" do
    StubContent.script(database: {:ok, %{"title" => "Release log", "status" => "current"}})

    html = expand(marker("native-embed:database", @board))

    assert html =~ "Release log"
    assert StubContent.questions() |> Enum.any?(&match?({:database, @board}, &1))
  end

  test "a database is drawn as the table it holds, columns in its own order" do
    StubContent.script(database: {:ok, table()})

    html = expand(marker("native-embed:database", @board))

    assert html =~ ~s(<table class="mirror-database-table">)
    assert headers(html) == ["Item", "Done", "Who"]
    assert html =~ "<td>First</td>"
    assert html =~ "<td>Yes</td>"
    assert html =~ ~s(href="#{@board}")
    refute html =~ "open the database in Confluence for all of it"
  end

  test "a user cell stays blank when nobody can name the account" do
    StubContent.script(database: {:ok, table()})

    html = expand(marker("native-embed:database", @board))

    refute html =~ "557058"
    assert cell_text(html, "Who") == ""
    assert StubContent.questions() |> Enum.any?(&match?({:person, "557058:abc"}, &1))
  end

  test "a user cell names everybody in it, not only the first" do
    StubContent.script(
      database: {:ok, table(who: ["557058:abc", "5f057cbe0b38b10022628d68"])},
      person: fn
        "557058:abc" -> "Ada Lovelace"
        "5f057cbe0b38b10022628d68" -> "Grace Hopper"
      end
    )

    html = expand(marker("native-embed:database", @board))

    assert cell_text(html, "Who") == "Ada Lovelace, Grace Hopper"
    refute html =~ "5f057cbe"
  end

  test "a person this mirror holds a page for is a link to it" do
    StubContent.script(
      database: {:ok, table()},
      person: fn _account_id -> "Ada Lovelace" end,
      person_page?: true
    )

    html = expand(marker("native-embed:database", @board))

    assert html =~ ~s(href="/people/557058%3Aabc")
    assert html =~ "Ada Lovelace"
  end

  test "a person with no page here is a name, not a link to nowhere" do
    StubContent.script(database: {:ok, table()}, person: fn _account_id -> "Ada Lovelace" end)

    html = expand(marker("native-embed:database", @board))

    assert cell_text(html, "Who") == "Ada Lovelace"
    refute html =~ "/people/"
  end

  test "a select cell is the label its option carries, not the option's id" do
    StubContent.script(database: {:ok, tagged()})

    html = expand(marker("native-embed:database", @board))

    assert cell_text(html, "Tag") == "test"
    refute html =~ "a28600c5"
  end

  test "a label some page here carries is a link into the taxonomy" do
    StubContent.script(database: {:ok, tagged()}, label?: true)

    html = expand(marker("native-embed:database", @board))

    assert html =~ ~s(href="/labels/test")
    assert StubContent.questions() |> Enum.any?(&match?({:label?, "test"}, &1))
  end

  test "a tag no page here carries is a word, because its page would be empty" do
    StubContent.script(database: {:ok, tagged()})

    html = expand(marker("native-embed:database", @board))

    assert cell_text(html, "Tag") == "test"
    refute html =~ "/labels/"
  end

  test "a table with more rows than a still draws says so" do
    StubContent.script(database: {:ok, table(truncated: true)})

    assert expand(marker("native-embed:database", @board)) =~
             "The table holds more rows than a still draws"
  end

  test "a still says which database it is, since the field names are its own words" do
    StubContent.script(database: {:ok, table()})

    document = expand(marker("native-embed:database", @board)) |> Floki.parse_fragment!()

    caption = document |> Floki.find("figcaption") |> Floki.text()
    assert caption =~ "Release log"
    assert caption =~ "in Confluence"
    assert Floki.attribute(document, "figcaption a", "href") == [@board]
  end

  test "a still wider than the column scrolls beside it instead of crushing its columns" do
    StubContent.script(database: {:ok, table()})

    document = expand(marker("native-embed:database", @board)) |> Floki.parse_fragment!()

    assert Floki.find(document, "div.mirror-table-scroll table.mirror-database-table") != []
  end

  test "a database whose rows may not be drawn is still named and linked" do
    StubContent.script(
      database:
        {:ok, %{"title" => "Locked", "fields" => [], "entries" => [], "truncated" => false}}
    )

    html = expand(marker("native-embed:database", @board))

    assert html =~ "Database “Locked”"
    assert html =~ ~s(href="#{@board}")
    refute html =~ "mirror-database-table"
  end

  test "an empty database is drawn with its columns and no rows" do
    StubContent.script(database: {:ok, table(entries: [])})

    html = expand(marker("native-embed:database", @board))

    assert html =~ "mirror-database-table"
    assert html =~ "<th>Item</th>"
    refute html =~ "<td>"
  end

  test "a database the mirror cannot read is still linked, and says so plainly" do
    StubContent.script(database: {:error, :not_found})

    html = expand(marker("native-embed:database", @board))

    assert html =~ "Database — drawn in Confluence; open it there."
    assert html =~ ~s(href="#{@board}")
  end

  test "a slide deck is drawn as its card, not claimed as a drawing" do
    StubContent.script(
      slide: {:ok, %{"title" => "Half-year review", "latestVersion" => %{"number" => 4}}}
    )

    html = expand(marker("native-embed:slide", @slides))

    assert html =~ ~s(class="mirror-slide-deck-title")
    assert html =~ "Half-year review"
    assert html =~ "Version 4 when it was read"
    assert html =~ ~s(href="#{@slides}")
    assert html =~ "publishes no slide document"
    assert StubContent.questions() |> Enum.any?(&match?({:slide, @slides}, &1))
  end

  test "a deck read before any version is known still carries its name" do
    StubContent.script(slide: {:ok, %{"title" => "Half-year review"}})

    html = expand(marker("native-embed:slide", @slides))

    assert html =~ "Half-year review"
    refute html =~ "Version"
  end

  test "a slide deck the mirror cannot read is still linked, and says so plainly" do
    StubContent.script(slide: {:error, :not_found})

    html = expand(marker("native-embed:slide", @slides))

    assert html =~ "Slides — drawn in Confluence; open it there."
    assert html =~ ~s(href="#{@slides}")
  end

  test "the plural spelling of the slides embed is the same embed" do
    StubContent.script(slide: {:ok, %{"title" => "Half-year review"}})

    assert expand(marker("native-embed:slides", @slides)) =~ "Half-year review"
  end

  test "an embed with no address says why it cannot be linked" do
    StubContent.script(whiteboard: {:ok, document("January")})

    assert expand(marker("native-embed:whiteboard", nil)) =~
             "the embed names no address, so the mirror cannot link to it"
  end

  # The columns and rows the port answers for a database: one text cell, one
  # checked box, and a user the mirror may not name.
  defp table(options \\ []) do
    who = Keyword.get(options, :who, "557058:abc")

    %{
      "title" => "Release log",
      "fields" => [
        %{"id" => "item", "name" => "Item", "type" => "text"},
        %{"id" => "done", "name" => "Done", "type" => "checkbox"},
        %{"id" => "who", "name" => "Who", "type" => "user"}
      ],
      "entries" =>
        Keyword.get(options, :entries, [
          %{
            "values" => %{
              "item" => %{"type" => "text", "plain" => "First"},
              "done" => %{"type" => "checkbox", "value" => true},
              "who" => %{
                "type" => "user",
                "value" => Enum.map(List.wrap(who), &%{"accountId" => &1})
              }
            }
          }
        ]),
      "truncated" => Keyword.get(options, :truncated, false)
    }
  end

  defp headers(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("table.mirror-database-table th")
    |> Enum.map(&Floki.text/1)
  end

  # The words in one column of the still, as a reader sees them.
  defp cell_text(html, column) do
    document = Floki.parse_fragment!(html)

    index =
      document
      |> Floki.find("table.mirror-database-table th")
      |> Enum.map(&Floki.text/1)
      |> Enum.find_index(&(&1 == column))

    document
    |> Floki.find("table.mirror-database-table tbody tr")
    |> Enum.map_join("|", fn row -> row |> Floki.find("td") |> Enum.at(index) |> Floki.text() end)
  end

  # A database whose only column is a select, as the v2 answers it: an option is
  # an id and the label a reader saw.
  defp tagged do
    %{
      "title" => "Release log",
      "fields" => [%{"id" => "tag", "name" => "Tag", "type" => "select"}],
      "entries" => [
        %{
          "values" => %{
            "tag" => %{
              "type" => "select",
              "value" => [%{"id" => "a28600c5-3a88-486e-809c-ffcd82179d03", "label" => "test"}]
            }
          }
        }
      ],
      "truncated" => false
    }
  end

  defp document(word) do
    %{
      "version" => "2024-05-20_ALPHA",
      "nodes" => %{
        "a" => %{
          "id" => "a",
          "type" => "shape",
          "zIndex" => 1,
          "geometry" => %{
            "position" => %{"x" => 10, "y" => 20},
            "size" => %{"x" => 200, "y" => 80}
          },
          "text" =>
            JSON.encode!(%{
              "type" => "doc",
              "content" => [%{"type" => "text", "text" => word}]
            })
        }
      },
      "edges" => %{}
    }
  end

  defp marker(name, url) do
    attributes =
      case url do
        nil -> ~s(data-macro="#{name}")
        url -> ~s(data-macro="#{name}" data-url="#{url}")
      end

    ~s(<div class="mirror-macro" #{attributes}></div>)
  end

  defp expand(marker) do
    DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})
  end

  # The drawing travels as a data URI, so its words are only visible once the
  # picture is decoded — which is what a reader's browser does.
  defp drawn_words(html) do
    with [_, base64] <- Regex.run(~r{data:image/svg\+xml;base64,([^"]+)}, html),
         {:ok, svg} <- Base.decode64(base64) do
      svg
    else
      _nothing_drawn -> ""
    end
  end
end
