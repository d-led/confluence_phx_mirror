defmodule ConfluencePhxMirror.Export.Site.ContentTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Export.Site.Content

  defp context do
    %{
      prefix: "../../../",
      pages: %{
        1002 => "spaces/ENG/pages/1002.html",
        1003 => "spaces/ENG/pages/1003.html"
      },
      origins: ["https://demo.atlassian.net/wiki", "https://demo.atlassian.net"],
      external: fn ids ->
        Map.new(ids, fn id ->
          {id, "https://demo.atlassian.net/wiki/pages/viewpage.action?pageId=#{id}"}
        end)
      end
    }
  end

  defp rewrite(html), do: Content.rewrite(html, context())

  describe "links between pages" do
    test "a page the archive carries becomes the file beside this one" do
      html = rewrite(~s(<p><a href="/spaces/ENG/pages/1002/Architecture+Overview">Arch</a></p>))

      assert html =~ ~s(href="../../../spaces/ENG/pages/1002.html")
    end

    test "a blog post is a page file as well" do
      html = rewrite(~s(<a href="/spaces/ENG/blog/1003/Release+Notes">Release</a>))

      assert html =~ ~s(href="../../../spaces/ENG/pages/1003.html")
    end

    test "a page the archive does not carry goes back to Confluence" do
      html = rewrite(~s(<a href="/spaces/ENG/pages/1009/Deprecated+Setup">Old</a>))

      assert html =~ ~s(href="https://demo.atlassian.net/wiki/pages/viewpage.action)
      refute html =~ "pages/1009.html"
    end

    test "the out-of-archive pages are asked for once, together" do
      parent = self()

      context =
        Map.put(context(), :external, fn ids ->
          send(parent, {:asked, ids})
          Map.new(ids, &{&1, "https://example.test/#{&1}"})
        end)

      Content.rewrite(
        ~s(<a href="/spaces/ENG/pages/1009/A">A</a><a href="/spaces/ENG/pages/1009/A">A</a>) <>
          ~s(<a href="/spaces/ENG/pages/1010/B">B</a><a href="/spaces/ENG/pages/1002/C">C</a>),
        context
      )

      assert_received {:asked, ids}
      assert Enum.sort(ids) == [1009, 1010]
    end
  end

  describe "pages named by their full address" do
    test "a page URL on the mirror's own site lands in the archive" do
      html =
        rewrite(
          ~s(<a href="https://demo.atlassian.net/wiki/pages/viewpage.action?pageId=1002">A</a>)
        )

      assert html =~ ~s(href="../../../spaces/ENG/pages/1002.html")
    end

    test "the site's address with Confluence's own page path as well" do
      html =
        rewrite(
          ~s(<a href="https://demo.atlassian.net/wiki/spaces/ENG/pages/1002/Architecture">A</a>)
        )

      assert html =~ ~s(href="../../../spaces/ENG/pages/1002.html")
    end

    test "another site's page, which is not ours to rewrite" do
      href = "https://other.atlassian.net/wiki/pages/viewpage.action?pageId=1002"

      assert rewrite(~s(<a href="#{href}">A</a>)) =~ ~s(href="#{href}")
    end
  end

  describe "files" do
    test "an attachment becomes a file in the archive" do
      html = rewrite(~s(<img src="/attachments/ENG/1002/9001/diagram.svg">))

      assert html =~ ~s(src="../../../attachments/ENG/1002/9001/diagram.svg")
    end

    test "an attachment's name is made safe for a file system" do
      html = rewrite(~s(<a href="/attachments/ENG/1002/9001/sync+diagram.svg">file</a>))

      assert html =~ ~s(href="../../../attachments/ENG/1002/9001/sync-diagram.svg")
    end

    test "a file on a page the archive does not carry is left as the body wrote it" do
      html = rewrite(~s(<img src="/attachments/ENG/1009/9/x.png">))

      assert html =~ ~s(src="/attachments/ENG/1009/9/x.png")
    end
  end

  describe "everything else" do
    test "a link to the web is left alone" do
      html = rewrite(~s(<a href="https://example.com/x">x</a>))

      assert html =~ ~s(href="https://example.com/x")
    end

    test "an anchor inside the page is left alone" do
      assert rewrite(~s(<a href="#overview">Overview</a>)) =~ ~s(href="#overview")
    end
  end

  describe "reading the page" do
    test "a heading carries the permalink the reader screens add with a script" do
      html = rewrite(~s(<h2 id="Overview">Overview</h2>))

      assert html =~ ~s(<a class="heading-anchor" href="#Overview")
    end

    test "the space between inline elements is not eaten by the rewrite" do
      html = rewrite(~s(<p><span class="status">A</span> <span class="status">B</span></p>))

      assert html =~ ~s(</span> <span)
    end
  end
end
