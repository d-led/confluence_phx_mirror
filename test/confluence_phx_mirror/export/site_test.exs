defmodule ConfluencePhxMirror.Export.SiteTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Export.Site.Search
  alias ConfluencePhxMirror.Mirror

  @stylesheet "/* the theme this site wears */"

  setup do
    demo_snapshot!()
    :ok
  end

  describe "the whole site" do
    setup %{} do
      %{files: archive(admin())}
    end

    test "is one folder of pages, its theme and its files", %{files: files} do
      assert Map.has_key?(files, "index.html")
      assert Map.has_key?(files, "assets/site.css")
      assert Map.has_key?(files, "spaces/ENG/index.html")
      assert Map.has_key?(files, "spaces/PROD/index.html")

      assert files["spaces/ENG/pages/#{Demo.open_page()}.html"] =~ Demo.open_page_title()
      assert files["spaces/ENG/pages/#{Demo.open_page()}.md"] =~ "## Overview"
    end

    test "carries the site's own stylesheet, not a copy per page", %{files: files} do
      assert files["assets/site.css"] == @stylesheet

      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]
      assert page =~ ~s(href="../../../assets/site.css")
      assert page =~ ~s(<html )
    end

    test "lists the spaces it holds", %{files: files} do
      index = files["index.html"]

      assert index =~ "Engineering Handbook"
      assert index =~ "Product Hub"
      assert index =~ ~s(href="spaces/ENG/index.html")
    end

    test "a space index carries its description and its pages", %{files: files} do
      index = files["spaces/ENG/index.html"]

      assert index =~ "How we build, test and run the platform."
      assert index =~ Demo.open_page_title()
      assert index =~ ~s(href="../../spaces/ENG/pages/#{Demo.open_page()}.html")
    end

    test "carries every page's attachments", %{files: files} do
      attachment =
        "attachments/ENG/#{Demo.open_page()}/#{Demo.open_page_attachment()}/" <>
          Demo.open_page_attachment_name()

      assert Map.has_key?(files, attachment)
      assert files[attachment] =~ "<svg"
    end

    test "a page's own furniture points inside the archive", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ ~s(href="../../../attachments/ENG/#{Demo.open_page()}/)
      assert page =~ ~s(href="../../../spaces/ENG/pages/#{Demo.open_page()}.md")
      assert page =~ "Original on Confluence"
    end

    test "needs no script: the heading permalinks are already in the page", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ ~s(class="heading-anchor")
      # The only script is the search page's, which asks for its own file.
      refute page =~ "<script"
    end

    test "carries a search index and the page that searches it", %{files: files} do
      index = files["assets/search.json"] |> JSON.decode!()

      assert Enum.any?(index, fn document ->
               document["title"] == Demo.open_page_title() and
                 document["url"] == "spaces/ENG/pages/#{Demo.open_page()}.html"
             end)

      assert Enum.any?(index, &(&1["space_key"] == "ENG"))
      assert Map.has_key?(files, "assets/search.js")

      search = files["search.html"]
      assert search =~ ~s(id="search-index")
      assert search =~ ~s(src="assets/search.js")
      assert search =~ Demo.open_page_title()
    end

    test "every page links to the copy's own search", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ ~s(action="../../../search.html")
    end
  end

  describe "links between pages" do
    test "a mirrored page links to the file, not to the mirror" do
      files = archive(admin())
      page = files["spaces/ENG/pages/#{Demo.crosslinks_page()}.html"]

      assert page =~ ~s(href="../../../spaces/ENG/pages/#{Demo.open_page()}.html")
      # Only the body's own link to the original stays, never a mirror path.
      refute page =~ ~s(href="/spaces/)
    end

    test "a page the archive does not carry links back to Confluence" do
      reader = Scope.for_user(user_fixture())
      files = archive(reader)

      refute Map.has_key?(files, "spaces/ENG/pages/#{Demo.restricted_page()}.html")

      page = files["spaces/ENG/pages/#{Demo.crosslinks_page()}.html"]

      assert page =~ "https://demo.atlassian.net/wiki/spaces/ENG/pages/#{Demo.restricted_page()}"
      refute page =~ "pages/#{Demo.restricted_page()}.html"
    end
  end

  describe "what a reader may take" do
    test "an administrator gets every page" do
      files = archive(admin())

      assert Map.has_key?(files, "spaces/ENG/pages/#{Demo.restricted_page()}.html")
    end

    test "a reader gets only the pages they may open" do
      files = archive(Scope.for_user(user_fixture()))

      assert Map.has_key?(files, "spaces/ENG/pages/#{Demo.open_page()}.html")
      refute Map.has_key?(files, "spaces/ENG/pages/#{Demo.restricted_page()}.html")
    end
  end

  describe "one space" do
    test "is the same folder, holding only that space" do
      space = Mirror.get_space_by_key("ENG")

      names =
        Export.space_site_archive(space, admin())
        |> Enum.map(&elem(&1, 0))

      assert "index.html" in names
      assert "spaces/ENG/index.html" in names
      refute "spaces/PROD/index.html" in names
      refute Enum.any?(names, &String.starts_with?(&1, "spaces/PROD/"))
    end
  end

  describe "the search index" do
    test "cannot close the script element it is inlined in" do
      json = Search.json([%{title: "</script><img>", text: "</SCRIPT>"}])

      refute json =~ "</script>"
      assert json =~ "\\u003c/script>"
    end
  end

  describe "the archive itself" do
    test "streams as a readable ZIP" do
      archive =
        Export.site_archive(admin(), stylesheet: @stylesheet)
        |> Export.Zip.chunks()
        |> unzip()

      assert Map.has_key?(archive, "index.html")
      assert Map.has_key?(archive, "spaces/ENG/pages/#{Demo.open_page()}.html")
    end

    test "names the download after the site" do
      assert Export.site_archive_name() == "Confluence Mirror site.zip"

      assert Export.space_site_archive_name(Mirror.get_space_by_key("ENG")) =~
               "Engineering Handbook site.zip"
    end
  end

  test "leaves the theme out when the instance has no stylesheet" do
    names =
      Export.site_archive(admin(), stylesheet: "")
      |> Enum.map(&elem(&1, 0))

    refute "assets/site.css" in names
    assert "index.html" in names
  end

  defp admin, do: Scope.for_user(Accounts.ensure_admin!())

  defp archive(scope) do
    Export.site_archive(scope, stylesheet: @stylesheet)
    |> Enum.to_list()
    |> Map.new(fn {name, data} ->
      {name, if(is_function(data, 0), do: data.(), else: data)}
    end)
  end

  defp unzip(chunks) do
    path =
      Path.join(System.tmp_dir!(), "mirror-site-#{System.unique_integer([:positive])}.zip")

    File.write!(path, chunks |> Enum.to_list() |> IO.iodata_to_binary())

    try do
      {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])
      Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
    after
      File.rm(path)
    end
  end
end
