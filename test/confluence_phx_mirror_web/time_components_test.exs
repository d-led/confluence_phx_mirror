defmodule ConfluencePhxMirrorWeb.TimeComponentsTest do
  @moduledoc """
  The server cannot know the reader's zone, so it hands over the instant — in
  UTC, the zone it stores — and marks the elements the browser should rewrite.
  These tests hold that contract; `assets/js/local_time.js` is what fills it in.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ConfluencePhxMirrorWeb.TimeComponents

  @at ~U[2026-10-21 09:30:00Z]

  describe "local_time/1" do
    test "carries the instant in UTC and says so until the browser takes over" do
      html = render(%{at: @at, format: :datetime})

      assert html =~ ~s(datetime="2026-10-21T09:30:00Z")
      assert html =~ ~s(data-local-time="datetime")
      assert html =~ "21 Oct 2026, 09:30 UTC"
      assert html =~ ~s(title="21 Oct 2026, 09:30 UTC")
    end

    test "a date asks the browser for the date only" do
      html = render(%{at: @at, format: :date})

      assert html =~ ~s(data-local-time="date")
      assert html =~ ">21 Oct 2026<"
    end

    test "claims no instant when the mirror never saw one" do
      html = render(%{at: nil, format: :datetime})

      refute html =~ "datetime="
      assert html =~ ">unknown<"
    end

    test "takes no tooltip marker of its own when the text is the instant" do
      refute render(%{at: @at, format: :datetime}) =~ "data-local-title"
    end
  end

  # `format` has a default in the component, but `attr` defaults are applied by
  # a caller's template, not by `render_component/2`, so the tests pass it.
  defp render(assigns) do
    render_component(&TimeComponents.local_time/1, assigns)
  end
end
