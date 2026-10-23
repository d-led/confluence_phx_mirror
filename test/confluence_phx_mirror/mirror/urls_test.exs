defmodule ConfluencePhxMirror.Mirror.URLsTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Mirror.URLs

  describe "content_path/2" do
    test "keeps Confluence's page URL shape" do
      page = %{confluence_id: 1002, slug: "Architecture+Overview", type: "page"}

      assert URLs.content_path("ENG", page) == "/spaces/ENG/pages/1002/Architecture+Overview"
    end

    test "puts blog posts under the space's blog" do
      post = %{confluence_id: 2001, slug: "Release+2+0", type: "blogpost"}

      assert URLs.content_path("PROD", post) == "/spaces/PROD/blog/2001/Release+2+0"
    end
  end

  test "escapes a segment instead of dropping its spaces" do
    assert URLs.attachment_path("ENG", 1002, 9001, "diagram final.svg") ==
             "/attachments/ENG/1002/9001/diagram%20final.svg"
  end
end
