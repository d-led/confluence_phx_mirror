defmodule ConfluencePhxMirror.Export.SiteTest do
  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Export
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

    test "files every page under the site's own mark", %{files: files} do
      # An ICO a browser can read: reserved zero, type 1, then its frames.
      assert <<0, 0, 1, 0, _frames::binary>> = files["assets/favicon.ico"]

      for {name, page} <- files, String.ends_with?(name, ".html") do
        assert [href] = icon_links(page), "#{name} names no mark for its tab"

        assert Map.has_key?(files, inside_archive(name, href)),
               "#{name} asks for #{href}, which the archive does not carry"
      end
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
      # The catalogue sits beside the label pages, not above them.
      assert catalogue =~ ~s(href="../labels/architecture.html")

      labelled = files["labels/architecture.html"]
      assert labelled =~ Demo.open_page_title()
      # The label pages sit one folder down: their links are relative to it.
      assert labelled =~ ~s(href="../spaces/ENG/pages/#{Demo.open_page()}.html")
      assert catalogue =~ ~s(href="../assets/site.css")
    end

    test "every link inside the archive points at a file the archive carries", %{files: files} do
      for {name, page} <- files,
          String.ends_with?(name, ".html"),
          {tag, attribute, href} <- relative_links(page) do
        assert Map.has_key?(files, inside_archive(name, href)),
               "#{name}: <#{tag} #{attribute}=\"#{href}\"> is not in the archive"
      end
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

      # The page loads the same documents `search.json` carries, as a script:
      # a folder opened from `file://` runs its own files but will not fetch
      # them.
      assert loaded_index(files) == index

      search = files["search.html"]
      assert search =~ ~s(src="assets/search-index.js")
      assert search =~ ~s(src="assets/search.js")
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
      assert script =~ "settle(box.value)"
      refute script =~ "run(box.value)"
    end

    test "the front page answers as the reader types, and fetches its index then", %{files: files} do
      front = files["index.html"]

      assert front =~ ~s(id="search-results")
      assert front =~ ~s(id="front-spaces")
      assert front =~ ~s(src="assets/search.js")
      assert front =~ ~s(data-index="assets/search-index.js")

      # Named, not shipped: the index is as large as the copy, and a reader who
      # came to look at the spaces should not wait for a scan nobody asked for.
      refute front =~ ~s(src="assets/search-index.js")

      script = files["assets/search.js"]
      assert script =~ ~s{getAttribute("data-index")}
      assert script =~ ~s{getElementById("front-spaces")}
    end

    test "every page links to the copy's own search", %{files: files} do
      page = files["spaces/ENG/pages/#{Demo.open_page()}.html"]

      assert page =~ ~s(action="../../../search.html")
      assert page =~ ~s(enterkeyhint="search")

      # The index travels with `search.html` and nowhere else, so on this page the
      # box is a form: Enter carries the word to the search page, which searches
      # as soon as it has loaded.
      refute page =~ "assets/search.js"
      refute page =~ "window.__MIRROR_SEARCH__"
    end

    test "the box in the header searches as you type, where the index is", %{files: files} do
      script = files["assets/search.js"]

      # `search.html` has two boxes asking one question, and it is the page that
      # holds the index — so both of them search live, and typing in the header
      # must not reload the page and parse the index a second time.
      assert files["search.html"] =~ ~s(name="q")
      assert script =~ ~s(form[role="search"] input[name="q"])
      assert script =~ ~s(header.form.addEventListener("submit")
    end

    test "a short list of spaces needs no filter", %{files: files} do
      # Two spaces fit in a sidebar; a field over them would be furniture.
      assert files["index.html"] =~ ~s(data-list="spaces")
      refute files["index.html"] =~ ~s(placeholder="Filter spaces")
    end

    test "the lists narrow and page without asking the network", %{files: files} do
      script = files["assets/site.js"]

      assert script =~ ~s{querySelectorAll("[data-list]")}
      # A page size is a reading preference, kept with the theme and the folded
      # tree, so it survives the next page the reader opens.
      assert script =~ "mirror-export:page-size"
      refute script =~ "http"
    end
  end

  describe "a copy bigger than one screen" do
    setup %{} do
      # Nine more spaces than a sidebar can show at once, and twelve labels the
      # catalogue can only list.
      for index <- 1..9, do: space_fixture(%{name: "Load test #{index}"})

      for index <- 1..12 do
        page = page_fixture(space_fixture(), %{title: "Topic #{index}"})
        {:ok, _labelled} = Mirror.replace_labels(page, ["topic-#{index}"])
      end

      %{files: archive(admin())}
    end

    test "the spaces in the sidebar narrow as the reader types", %{files: files} do
      for page <- ["index.html", "search.html", "labels/index.html"] do
        assert files[page] =~ ~s(data-list="spaces")
        assert files[page] =~ ~s(placeholder="Filter spaces")
        assert files[page] =~ ~s(data-filter="true")
      end
    end

    test "the label catalogue offers a filter and a page size", %{files: files} do
      catalogue = files["labels/index.html"]

      assert catalogue =~ ~s(data-list="labels")
      assert catalogue =~ ~s(placeholder="Filter labels")
      assert catalogue =~ ~s(<option value="10">10</option>)
      assert catalogue =~ ~s(<option value="100" selected>100</option>)
      assert catalogue =~ ~s(<option value="1000">1000</option>)
    end

    test "the controls wait for the script that makes them work", %{files: files} do
      # Every row is in the file, so a reader without the script sees the whole
      # list and no buttons that do nothing.
      catalogue = files["labels/index.html"]

      assert catalogue =~ ~s(data-controls style="display: none")
      assert catalogue =~ "topic-1"
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

  defp icon_links(page) do
    page
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(link[rel="icon"]))
    |> LazyHTML.attribute("href")
  end

  # A link written from the page's own folder, read from the archive's root.
  defp inside_archive(name, href) do
    href
    |> Path.expand(Path.dirname("/" <> name))
    |> String.trim_leading("/")
  end

  # What a reader can follow to another file in the folder. An address with a
  # scheme leaves the archive on purpose, and a bare `#` stays on the page.
  defp relative_links(page) do
    document = LazyHTML.from_fragment(page)

    for {tag, attribute} <- [{"a", "href"}, {"img", "src"}, {"link", "href"}, {"script", "src"}],
        href <- LazyHTML.attribute(LazyHTML.query(document, tag), attribute),
        href != "",
        not String.starts_with?(href, ["#", "http:", "https:", "mailto:", "data:"]),
        do: {tag, attribute, href}
  end

  # What `search.html` holds once it has loaded `assets/search-index.js`.
  defp loaded_index(files) do
    files["assets/search-index.js"]
    |> String.replace_prefix("window.__MIRROR_SEARCH__ = ", "")
    |> String.trim_trailing(";\n")
    |> JSON.decode!()
  end

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
