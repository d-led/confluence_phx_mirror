defmodule ConfluencePhxMirror.Sync.DynamicContent.AttachmentsTest do
  @moduledoc """
  *Attachments* lists the mirror's own files, so the test is about the link a
  reader clicks: it has to be the reader route for this page's blob.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.DynamicContent
  alias ConfluencePhxMirror.Sync.DynamicContent.StubContent

  @marker ~s(<div class="mirror-macro" data-macro="attachments"></div>)
  @space %{key: "ENG"}
  @host %{id: 1, confluence_id: 1001, slug: "page-1001", title: "Runbooks", space: @space}

  setup do
    StubContent.script(
      attachments: [
        file(9001, "diagram.svg", "image/svg+xml", 2048),
        file(9002, "runbook.pdf", "application/pdf", 3_145_728)
      ]
    )
  end

  test "lists the page's files in the order the port answers" do
    assert filenames(expand()) == ["diagram.svg", "runbook.pdf"]
  end

  test "links each file at its mirrored blob" do
    assert hrefs(expand()) == [
             "/attachments/ENG/1001/9001/diagram.svg",
             "/attachments/ENG/1001/9002/runbook.pdf"
           ]
  end

  test "says what each file is and how big it is" do
    assert expand() =~ "image/svg+xml · 2 KB"
    assert expand() =~ "application/pdf · 3.0 MB"
  end

  test "asks about the page carrying the macro" do
    expand()

    assert StubContent.questions() == [{:attachments, 1001}]
  end

  test "draws for a page whose space is not loaded, as a run holds one while it writes" do
    html =
      DynamicContent.expand(@marker, %{
        space: @space,
        page: Map.delete(@host, :space),
        source: StubContent
      })

    assert hrefs(html) == [
             "/attachments/ENG/1001/9001/diagram.svg",
             "/attachments/ENG/1001/9002/runbook.pdf"
           ]
  end

  test "says so when the page has no files" do
    StubContent.script(attachments: [])

    assert text(expand()) == "This page has no attachments."
  end

  defp expand(marker \\ @marker),
    do: DynamicContent.expand(marker, %{space: @space, page: @host, source: StubContent})

  defp filenames(html), do: html |> links() |> Enum.map(&Floki.text/1)
  defp hrefs(html), do: html |> links() |> Enum.map(&href/1)

  defp href(link), do: link |> Floki.attribute("href") |> List.first()

  defp links(html), do: html |> Floki.parse_fragment!() |> Floki.find("ul.mirror-files a")

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text()

  defp file(confluence_id, filename, media_type, byte_size) do
    %{
      confluence_id: confluence_id,
      filename: filename,
      media_type: media_type,
      byte_size: byte_size
    }
  end
end
