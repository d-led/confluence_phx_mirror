defmodule ConfluencePhxMirror.Sync.EmoticonsTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.Emoticons

  describe "from_attributes/1" do
    test "a classic emoticon name is the symbol Confluence draws" do
      assert Emoticons.from_attributes([{"ac:name", "tick"}]) == "✅"
    end

    test "the stored fallback character wins, because it is what Confluence shows" do
      assert Emoticons.from_attributes([
               {"ac:name", "rocket"},
               {"ac:emoji-shortname", ":rocket:"},
               {"ac:emoji-fallback", "🚀"}
             ]) == "🚀"
    end

    test "a fallback Confluence wrote as an escape is the character it names" do
      assert Emoticons.from_attributes([
               {"ac:name", "blue-star"},
               {"ac:emoji-shortname", ":calendar_spiral:"},
               {"ac:emoji-id", "1f5d3"},
               {"ac:emoji-fallback", "\\uD83D\\uDDD3"}
             ]) == "🗓"
    end

    test "an escape that names no character is not a fallback" do
      assert Emoticons.from_attributes([
               {"ac:emoji-shortname", ":check_mark:"},
               {"ac:emoji-fallback", "\\uD83D"}
             ]) == "✅"
    end

    test "a short name without a fallback still resolves" do
      assert Emoticons.from_attributes([{"ac:emoji-shortname", ":check_mark:"}]) == "✅"
    end

    test "a fallback that is itself a shortcode is not a character" do
      assert Emoticons.from_attributes([
               {"ac:name", "smile"},
               {"ac:emoji-fallback", ":smile:"}
             ]) == "🙂"
    end

    test "a code point names the emoji when nothing else does" do
      assert Emoticons.from_attributes([{"ac:emoji-id", "1f44d"}]) == "👍"
      assert Emoticons.from_attributes([{"ac:emoji-id", "1f1e9-1f1ea"}]) == "🇩🇪"
    end

    test "an emoji from Confluence's own set is the nearest character" do
      assert Emoticons.from_attributes(big_grin_attributes()) == "😁"
      assert Emoticons.from_attributes([{"ac:emoji-id", "atlassian-big_grin"}]) == "😁"
    end

    test "unknown markup has no character" do
      assert Emoticons.from_attributes([{"ac:name", "no-such-emoticon"}]) == nil
    end
  end

  describe "from_storage/2" do
    test "the shortcode Confluence's export writes as text becomes the character" do
      storage = """
      <p>what a nice page! <ac:emoticon ac:name="blue-star" ac:emoji-shortname=":big_grin:"
           ac:emoji-id="atlassian-big_grin" ac:emoji-fallback=":big_grin:" /> !!!</p>
      """

      converted = Emoticons.from_storage("<p>what a nice page! :big_grin: !!!</p>", storage)

      assert converted == "<p>what a nice page! 😁 !!!</p>"
    end

    test "a shortcode the storage does not name is prose and stays" do
      assert Emoticons.from_storage(
               "<p>:wink: and :big_grin:</p>",
               storage(big_grin_attributes())
             ) ==
               "<p>:wink: and 😁</p>"
    end

    test "a shortcode inside a code block is typed, not picked" do
      html = "<p>:big_grin:</p><pre><code>:big_grin: = 1</code></pre>"

      assert Emoticons.from_storage(html, storage(big_grin_attributes())) ==
               "<p>😁</p><pre><code>:big_grin: = 1</code></pre>"
    end

    test "a page without storage is left as it is" do
      assert Emoticons.from_storage("<p>:big_grin:</p>", nil) == "<p>:big_grin:</p>"
      assert Emoticons.from_storage(nil, "<p/>") == nil
    end
  end

  describe "from_image/1" do
    test "an export-view emoticon image is its symbol" do
      assert Emoticons.from_image(
               attributes("""
               <img class="emoticon emoticon-tick" data-emoji-id="atlassian-check_mark"
                    data-emoji-shortname=":check_mark:" data-emoji-fallback=":check_mark:"
                    src="https://dled.atlassian.net/wiki/s/-1509737426/6452/_/images/icons/emoticons/check.png"
                    width="16" height="16" data-emoticon-name="tick" alt="(tick)" />
               """)
             ) == "✅"
    end

    test "the character Confluence stored for a modern emoji wins" do
      assert Emoticons.from_image(
               attributes("""
               <img class="emoticon emoticon-smile" data-emoji-id="1f642"
                    data-emoji-shortname=":slight_smile:" data-emoji-fallback="🙂"
                    src="https://dled.atlassian.net/wiki/images/icons/emoticons/smile.png"
                    alt="(smile)" />
               """)
             ) == "🙂"
    end

    test "the fallback an export writes as an escape is the character it names" do
      assert Emoticons.from_image(
               attributes("""
               <img class="emoticon emoticon-blue-star" data-emoji-shortname=":calendar_spiral:"
                    data-emoji-id="1f5d3" data-emoji-fallback="\\uD83D\\uDDD3"
                    src="https://dled.atlassian.net/wiki/images/icons/emoticons/star_blue.png" />
               """)
             ) == "🗓"
    end

    test "the file name still names the emoticon when no data attributes survive" do
      assert Emoticons.from_image([
               {"class", "emoticon"},
               {"src", "/wiki/images/icons/emoticons/thumbs-up.svg"}
             ]) == "👍"
    end

    test "another image stays an image, even when its name sounds like a face" do
      assert Emoticons.from_image([
               {"class", "confluence-embedded-image"},
               {"src", "/download/attachments/1/smile.png"}
             ]) == nil
    end
  end

  describe "html/1" do
    test "a body mirrored before this existed gets its emoticons" do
      html = """
      <p>Ship it <img class="emoticon emoticon-tick" data-emoticon-name="tick"
                      alt="(tick)" src="https://dled.atlassian.net/wiki/images/icons/emoticons/check.png" />
         and <ac:emoticon ac:name="smile"/> — but :) and (y) are prose.</p>
      """

      converted = Emoticons.html(html)

      assert converted =~ "Ship it ✅"
      assert converted =~ "and 🙂"
      assert converted =~ "but :) and (y) are prose"
      refute converted =~ "<img"
      refute converted =~ "ac:emoticon"
    end

    test "a body that already carries the characters is unchanged" do
      html = "<p>Ship it ✅</p>"

      assert Emoticons.html(html) == html
    end

    test "an image it cannot name is left alone" do
      html =
        ~s(<img class="transform-error" src="https://dled.atlassian.net/placeholder/error" />)

      assert Emoticons.html(html) == html
    end

    test "a character Confluence stored as an escape is the character" do
      html = "<h2>\\uD83E\\uDD14 Problem statement</h2>"

      assert Emoticons.html(html) == "<h2>🤔 Problem statement</h2>"
    end

    test "an escape inside code, or in an attribute, is what somebody wrote" do
      html = ~s(<pre><code>x = "\\uD83E\\uDD14"</code></pre><a title="\\uD83E\\uDD14">t</a>)

      assert Emoticons.html(html) == html
    end

    test "an escape that names no character is left as it was written" do
      assert Emoticons.html("<p>\\uD83E</p>") == "<p>\\uD83E</p>"
    end
  end

  # The attribute list of a tag, the way the renderer sees it.
  defp attributes(tag) do
    ~r/([\w:-]+)\s*=\s*"([^"]*)"/
    |> Regex.scan(tag, capture: :all_but_first)
    |> Enum.map(fn [name, value] -> {name, value} end)
  end

  # Confluence's own emoji, as the editor stores one: a classic name for the
  # image, an id and a shortname for the emoji, and no fallback character.
  defp big_grin_attributes do
    [
      {"ac:name", "blue-star"},
      {"ac:emoji-shortname", ":big_grin:"},
      {"ac:emoji-id", "atlassian-big_grin"},
      {"ac:emoji-fallback", ":big_grin:"}
    ]
  end

  defp storage(attrs) do
    tags = Enum.map_join(attrs, " ", fn {name, value} -> ~s(#{name}="#{value}") end)
    "<p><ac:emoticon #{tags} /></p>"
  end
end
