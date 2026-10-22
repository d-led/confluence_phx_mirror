defmodule ConfluencePhxMirror.ExportTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Mirror

  setup do
    demo_snapshot!()
    :ok
  end

  describe "a page export" do
    test "carries Confluence metadata as front matter and the body as Markdown" do
      markdown = Export.page_markdown(Mirror.get_page!(1002))

      assert markdown =~ ~s(title: "Architecture Overview")
      assert markdown =~ "confluence_id: 1002"
      assert markdown =~ "labels: [architecture, design]"
      assert markdown =~ "## Overview"
      assert markdown =~ "## The pipeline"
    end

    test "names the file after the title" do
      assert Export.page_filename(Mirror.get_page!(1002)) == "Architecture Overview.md"
    end
  end

  describe "a space archive" do
    setup do
      %{entries: Export.space_archive(Mirror.get_space_by_key("ENG")) |> Enum.to_list()}
    end

    test "mirrors the page hierarchy as folders", %{entries: entries} do
      names = entry_names(entries)

      assert "Engineering Handbook/index.md" in names
      assert "Engineering Handbook/Engineering Handbook.md" in names
      assert "Engineering Handbook/Getting Started/Getting Started.md" in names

      assert "Engineering Handbook/Getting Started/Architecture Overview/Architecture Overview.md" in names
      assert "Engineering Handbook/Archived/Deprecated Setup.md" in names
    end

    test "links pages relatively and includes their attachments", %{entries: entries} do
      assert %{
               "Engineering Handbook/Getting Started/Architecture Overview/Architecture Overview.md" =>
                 markdown
             } = Map.new(entries)

      assert markdown =~ "[Getting Started](../Getting Started.md)"
      assert markdown =~ "![Sync architecture diagram](attachments/diagram.svg)"

      attachment =
        "Engineering Handbook/Getting Started/Architecture Overview/attachments/diagram.svg"

      assert attachment in entry_names(entries)
    end

    test "reads attachment bytes only while the archive is written", %{entries: entries} do
      assert {_name, data} =
               Enum.find(entries, fn {name, _} ->
                 String.ends_with?(name, "attachments/diagram.svg")
               end)

      assert is_function(data, 0)
      assert is_binary(data.())
    end
  end

  test "blog posts land in a Blog folder" do
    names =
      Mirror.get_space_by_key("PROD")
      |> Export.space_archive()
      |> Enum.map(&elem(&1, 0))

    assert "Product Hub/Blog/Release 2.0.md" in names
  end

  test "the archive stream produces a readable ZIP" do
    archive =
      Mirror.get_space_by_key("ENG")
      |> Export.space_archive()
      |> Export.Zip.chunks()
      |> archive_contents()

    assert Map.has_key?(archive, "Engineering Handbook/index.md")

    assert Map.has_key?(
             archive,
             "Engineering Handbook/Getting Started/Architecture Overview/attachments/diagram.svg"
           )
  end

  describe "a space archive for one reader" do
    test "omits pages the reader may not open" do
      names =
        "ENG"
        |> Mirror.get_space_by_key()
        |> Export.space_archive(Scope.for_user(user_fixture()))
        |> Enum.to_list()
        |> entry_names()

      refute Enum.any?(names, &String.contains?(&1, "Macros Gallery"))
    end

    test "keeps every page for an administrator" do
      names =
        "ENG"
        |> Mirror.get_space_by_key()
        |> Export.space_archive(Scope.for_user(Accounts.ensure_admin!()))
        |> Enum.to_list()
        |> entry_names()

      assert Enum.any?(names, &String.contains?(&1, "Macros Gallery"))
    end
  end

  defp entry_names(entries), do: Enum.map(entries, &elem(&1, 0))

  defp archive_contents(chunks) do
    path = Path.join(System.tmp_dir!(), "mirror-export-#{System.unique_integer([:positive])}.zip")
    File.write!(path, chunks |> Enum.to_list() |> IO.iodata_to_binary())

    try do
      {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])
      Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
    after
      File.rm(path)
    end
  end
end
