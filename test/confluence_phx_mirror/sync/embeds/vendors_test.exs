defmodule ConfluencePhxMirror.Sync.Embeds.VendorsTest do
  @moduledoc """
  The vendors whose player needs an address of its own.

  The template a widget connector stores is what knows *what the address is*, so
  this is where "a YouTube address" becomes "the address YouTube's player is
  served from". A vendor nobody has seen is not guessed at, and an address that
  cannot be turned into a player's address is refused rather than approximated.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.Embeds.Vendors

  @template "com/atlassian/confluence/extra/widgetconnector/templates/youtube.vm"

  describe "the vendor a macro names" do
    test "the template's file name says it" do
      assert Vendors.name(@template, nil) == "youtube"
    end

    # The capture page records both, so whichever arrives first is enough.
    test "the overlay says it when the template is missing" do
      assert Vendors.name(nil, "youtube") == "youtube"
    end

    test "a vendor nobody has seen is not guessed at" do
      assert Vendors.name(
               "com/atlassian/confluence/extra/widgetconnector/templates/vimeo.vm",
               nil
             ) ==
               nil

      assert Vendors.name(nil, "vimeo") == nil
      assert Vendors.name(nil, nil) == nil
    end
  end

  describe "the address a YouTube frame needs" do
    @watch "https://www.youtube.com/watch?v=ii1waoqualY"
    @embed "https://www.youtube.com/embed/ii1waoqualY"

    test "a watch page is the player's own address" do
      assert Vendors.frame_source("youtube", @watch) == {:ok, @embed}
    end

    # The short link is the one people paste; the frame still loads youtube.com,
    # so the deployment names one host and no request reaches the shortener.
    test "a short link is the same video" do
      assert Vendors.frame_source("youtube", "https://youtu.be/ii1waoqualY") == {:ok, @embed}
    end

    test "a phone's link and a short are the same video" do
      assert Vendors.frame_source("youtube", "https://m.youtube.com/watch?v=ii1waoqualY") ==
               {:ok, @embed}

      assert Vendors.frame_source("youtube", "https://www.youtube.com/shorts/ii1waoqualY") ==
               {:ok, @embed}
    end

    test "an address that is already the player's is left alone" do
      assert Vendors.frame_source("youtube", @embed) == {:ok, @embed}
    end

    test "a playlist is the player's list form" do
      assert Vendors.frame_source(
               "youtube",
               "https://www.youtube.com/playlist?list=PLii1waoqualY"
             ) ==
               {:ok, "https://www.youtube.com/embed/videoseries?list=PLii1waoqualY"}

      assert Vendors.frame_source(
               "youtube",
               "https://www.youtube.com/embed/videoseries?list=PLii1waoqualY"
             ) == {:ok, "https://www.youtube.com/embed/videoseries?list=PLii1waoqualY"}
    end

    # A timestamp is not part of the video: the address under the frame keeps it,
    # and the frame plays from the start.
    test "the rest of the query is not the video" do
      assert Vendors.frame_source("youtube", @watch <> "&t=90") == {:ok, @embed}
    end

    test "a YouTube address the player cannot take is refused" do
      assert Vendors.frame_source("youtube", "https://www.youtube.com/feed/subscriptions") ==
               :error

      assert Vendors.frame_source("youtube", "https://www.youtube.com/watch") == :error
    end

    test "an address somewhere else is not a YouTube video, whatever the template says" do
      assert Vendors.frame_source("youtube", "https://example.com/watch?v=ii1waoqualY") == :error
    end

    # The id is pasted into an address, so it is checked for the shape an id has
    # rather than trusted.
    test "an id that is not one is refused, not pasted into the frame's address" do
      refute match?({:ok, _}, Vendors.frame_source("youtube", "https://youtu.be/a b"))
      refute match?({:ok, _}, Vendors.frame_source("youtube", @watch <> "%3Flist%3Devil"))
      refute match?({:ok, _}, Vendors.frame_source("youtube", "https://youtu.be/../evil"))
    end
  end
end
