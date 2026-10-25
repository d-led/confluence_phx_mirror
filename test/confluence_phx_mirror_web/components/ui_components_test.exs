defmodule ConfluencePhxMirrorWeb.UIComponentsTest do
  @moduledoc """
  A resource card answers two questions at once: how much this holds, and how
  much of the box it is holding it on. The second one needs three parts — what
  is ours, what everything else put there, and what is free — or a mirror that
  occupies two megabytes of a disk a build cache filled reads as the culprit.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ConfluencePhxMirrorWeb.UIComponents

  @megabyte 1024 * 1024

  describe "resource_meter/1" do
    test "splits a used device into our slice and everything else's" do
      html = render(value: 10 * @megabyte, percent: 50, share: 10.0)

      assert html =~ ~s(aria-label="Data mount: 10.0% of it ours, 50% of the device used")
      assert html =~ ~s(title="ours: 10.0%")
      assert html =~ ~s(style="width: 40.0%")
      refute html =~ "<progress"
    end

    test "draws the split even when our own slice rounds down to nothing" do
      html = render(value: @megabyte, percent: 50, share: 0.0)

      assert html =~ ~s(style="width: 0.0%; min-width: 2px")
      assert html =~ ~s(style="width: 50.0%")
    end

    test "keeps an empty slice empty when the resource holds nothing" do
      html = render(value: 0, percent: 50, share: 0.0)

      refute html =~ "min-width"
    end

    test "never claims more of the device than is used" do
      # The resource and the device are measured at different moments, so a
      # rounding can put our slice past the used part.
      html = render(value: 10 * @megabyte, percent: 30, share: 40.0)

      assert html =~ ~s(title="ours: 30.0%")
      assert html =~ ~s(style="width: 0.0%" title="everything else: 0.0%")
    end

    test "rings a device that is nearly full" do
      assert render(value: @megabyte, percent: 91, share: 1.0) =~ "ring-error/60"
      assert render(value: @megabyte, percent: 80, share: 1.0) =~ "ring-warning/60"
      refute render(value: @megabyte, percent: 20, share: 1.0) =~ "ring-"
    end

    test "keeps one bar when nobody said how the device splits" do
      html = render(value: 10 * @megabyte, percent: 50)

      assert html =~ "<progress"
      assert html =~ ~s(aria-label="Data mount: 50% used")
      refute html =~ "of it ours"
    end

    test "draws no bar at all for a device that did not report its size" do
      html = render(value: 10 * @megabyte, percent: nil, share: nil)

      refute html =~ "<progress"
      refute html =~ "aria-label"
      assert html =~ "10.0 MB"
    end
  end

  defp render(assigns) do
    render_component(
      &UIComponents.resource_meter/1,
      Keyword.merge([id: "meter", label: "Data mount"], assigns)
    )
  end
end
