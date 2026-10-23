defmodule ConfluencePhxMirror.Mirror.PageSlugTest do
  @moduledoc """
  The URL segment Confluence puts after the page id. The expectations come from
  Confluence Cloud itself: the titles below were created there and the segments
  are what its own `_links.webui` returned.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.Page
  alias ConfluencePhxMirror.Mirror.URLs

  describe "slugify/1" do
    test "keeps ASCII words, turns every other run into one +" do
      assert Page.slugify("API /v2: changelog? (draft) #2") == "API+v2+changelog+draft+2"
      assert Page.slugify("Rocket 🚀 launch") == "Rocket+launch"
      assert Page.slugify("Leading   and    inner   spaces") == "Leading+and+inner+spaces"
    end

    test "drops accented letters the way Confluence does" do
      # Its own URL for "Ünïcode Ünïts — Ölçüm" is /n+code+n+ts+l+m.
      assert Page.slugify("Ünïcode Ünïts — Ölçüm") == "n+code+n+ts+l+m"
    end

    test "leaves nothing when no ASCII word survives" do
      assert Page.slugify("Обзор проекта") == ""
      assert Page.slugify("测试页面") == ""
      assert Page.slugify("!!! ???") == ""
    end

    test "keeps the case and the underscores Confluence keeps" do
      assert Page.slugify("V2_Changelog") == "V2_Changelog"
    end

    test "trims a trailing separator after the length cap" do
      slug = Page.slugify(String.duplicate("word ", 60))

      refute String.ends_with?(slug, "+")
      assert String.length(slug) <= 255
    end
  end

  describe "slug_match?/2" do
    test "a plus and an encoded space name the same page" do
      page = %Page{slug: "API+v2+changelog"}

      assert Page.slug_match?(page, "API+v2+changelog")
      assert Page.slug_match?(page, "API v2 changelog")
    end

    test "anything else is a different page, and gets redirected" do
      page = %Page{slug: "API+v2+changelog"}

      refute Page.slug_match?(page, "something-else")
      refute Page.slug_match?(page, "APIv2changelog")
    end

    test "a page served by id alone matches an empty segment" do
      page = %Page{slug: ""}

      assert Page.slug_match?(page, "")
      assert Page.slug_match?(page, nil)
      refute Page.slug_match?(page, "any-title")
    end
  end

  describe "canonical URLs" do
    test "carry the title segment when there is one" do
      assert URLs.page_path("MFS", 8_159_233, "API+v2+changelog") ==
               "/spaces/MFS/pages/8159233/API+v2+changelog"
    end

    test "are the id alone when the title has nothing usable" do
      assert URLs.page_path("MFS", 8_126_481, "") == "/spaces/MFS/pages/8126481"
    end

    test "keep non-ASCII out of the path but never mangle a plus" do
      assert URLs.page_path("MFS", 1, "n+code") == "/spaces/MFS/pages/1/n+code"
      assert URLs.blog_post_path("MFS", 2, "") == "/spaces/MFS/blog/2"
    end
  end
end
