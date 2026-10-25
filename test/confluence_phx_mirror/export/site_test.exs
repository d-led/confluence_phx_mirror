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

    test "a page carries its own trail, not the whole space tree", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ "All pages in ENG"
      # The tree would link every sibling; the trail links only the way here,
      # and the tree itself is on the space's front page, once.
      refute page =~ "pages/#{Demo.restricted_page()}.html"
    end

    test "reads without scripts: its anchors and its text are already there", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ ~s(class="heading-anchor")
      # The two scripts only add a folding tree and a theme switch; neither
      # builds the content, so the page reads the same with them blocked.
      assert page =~ ~s(src="../../../assets/theme.js")
      assert page =~ ~s(src="../../../assets/site.js")
    end

    test "lets the reader fold the page tree away", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ "data-site-sidebar-toggle"
      assert page =~ ~s(aria-controls="site-sidebar")
      assert page =~ ~s(id="site-sidebar")
      assert page =~ "data-site-backdrop"
    end

    test "follows the system's theme until the reader pins one", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      # The name is what the scripts switch on; the variant they apply is the
      # reader's, and it is applied before the body, so no page flashes white.
      assert page =~ "data-theme-name="
      assert page =~ "data-site-theme"

      head = page |> String.split("<body", parts: 2) |> hd()
      assert head =~ ~s(src="../../../assets/theme.js")
    end

    test "the scripts travel with the folder and ask nothing of the network", %{files: files} do
      assert files["assets/site.js"] =~ "mirror-export:sidebar"
      assert files["assets/theme.js"] =~ "mirror-export:variant"
      refute files["assets/site.js"] =~ "http"
      refute files["assets/theme.js"] =~ "http"
    end

    test "a page carries its comments, replies included", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page_parent()}.html"]

      assert page =~ ~s(id="comments")
      assert page =~ "Sam Rivera"
      assert page =~ "VPN steps"
      # The reply hangs under its parent, the way the reader screen draws it.
      assert page =~ "Jane Doe"
    end

    test "carries a label catalogue and a page for each label", %{files: files} do
      catalogue = files["labels/index.html"]

      assert catalogue =~ "architecture"
      assert catalogue =~ "labels/architecture.html"

      labelled = files["labels/architecture.html"]
      assert labelled =~ Demo.open_page_title()
      # The label pages sit one folder down: their links are relative to it.
      assert labelled =~ ~s(href="../spaces/ENG/pages/#{Demo.open_page()}.html")
      assert catalogue =~ ~s(href="../assets/site.css")
    end

    test "a page's label chips lead into the catalogue", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ ~s(href="../../../labels/architecture.html")
    end

    test "a space front page shows its categories", %{files: files} do
      assert files["spaces/ENG/index.html"] =~ "platform"
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

    test "a search says it is working, and how far it has got", %{files: files} do
      search = files["search.html"]

      assert search =~ ~s(id="search-spinner" hidden)
      assert search =~ ~s(aria-busy="false")

      # The running commentary is for the eye; only the finished count is
      # announced, so a screen reader is not read the progress bar.
      assert search =~ ~s(id="search-progress" aria-hidden="true")
      assert search =~ ~s(id="search-status" role="status")

      script = files["assets/search.js"]
      assert script =~ "Searching…"
      assert script =~ ~s(results.setAttribute("aria-busy")
    end

    test "a search waits for the typing to settle before it scans", %{files: files} do
      script = files["assets/search.js"]

      # Every keystroke settles the field; none of them starts a scan of its
      # own, so a word typed at speed is scanned once, not once per letter.
      assert script =~ "settle(input.value)"
      refute script =~ "run(input.value)"
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

    test "names the download after the site and the moment it was made" do
      at = ~U[2026-10-26 10:15:30Z]

      assert Export.site_archive_name(at) == "confluence_mirror_site_20261026T101530Z.zip"

      assert Export.space_site_archive_name(Mirror.get_space_by_key("ENG"), at) ==
               "engineering_handbook_site_20261026T101530Z.zip"
    end

    test "turns a space's own name into words a save dialog keeps" do
      at = ~U[2026-10-26 10:15:30Z]
      space = %Mirror.Space{name: "Café: notes/ideas"}

      assert Export.space_site_archive_name(space, at) ==
               "cafe_notes_ideas_site_20261026T101530Z.zip"

      assert Export.archive_name(space, at) ==
               "cafe_notes_ideas_markdown_20261026T101530Z.zip"
    end

    test "falls back to a key or an id when a name will not survive a file name" do
      at = ~U[2026-10-26 10:15:30Z]
      space = %Mirror.Space{name: "Привет", key: "PRIVET"}

      assert Export.space_site_archive_name(space, at) == "privet_site_20261026T101530Z.zip"

      page = %Mirror.Page{title: "Привет", confluence_id: 4_242}
      assert Export.page_filename(page) == "page_4242.md"
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
