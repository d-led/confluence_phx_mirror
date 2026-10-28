defmodule ConfluencePhxMirror.Sync.VendorMacrosTest do
  @moduledoc """
  Third-party layout macros drawn from what the page itself carries.

  Each spec is a storage node in and HTML out — no database, no source — because
  that is the whole promise of an extension: everything it needs was on the page
  Confluence stored.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.VendorMacros

  test "an app's elements are registered by their own ac:name" do
    assert "aura-tab-group" in VendorMacros.names()
    assert "karma-row" in VendorMacros.names()
    assert "confiform-table" not in VendorMacros.names()
  end

  test "a macro no extension understands is left to the caller" do
    assert VendorMacros.draw("pivot-table", %{}, []) == :error
  end

  describe "Aura" do
    test "a tab keeps its body, behind a summary a reader can click" do
      assert {:ok, [{"details", _attrs, [{"summary", _, ["Install"]} | body]}]} =
               VendorMacros.draw("aura-tab", %{"title" => "Install"}, [
                 {"p", [], ["Run mix setup."]}
               ])

      assert body == [{"p", [], ["Run mix setup."]}]
    end

    test "a tab group wraps its tabs" do
      assert {:ok, [{"div", [{"class", "mirror-aura-tabs"}], [_tab]}]} =
               VendorMacros.draw("aura-tab-group", %{}, [{"details", [], []}])
    end

    test "a progress bar keeps the value it was given, because that is the number" do
      assert {:ok, [{"div", attrs, [{"span", bar, ["40%"]}]}]} =
               VendorMacros.draw("aura-progress-bar", %{"value" => "40"}, [])

      assert {"aria-valuenow", "40"} in attrs
      assert {"style", "width: 40%"} in bar
    end

    test "a value that is not a percentage is held to the ends of the bar" do
      assert {:ok, [{"div", _, [{"span", withdrawn, _}]}]} =
               VendorMacros.draw("aura-progress-bar", %{"value" => "lots"}, [])

      assert {"style", "width: 0%"} in withdrawn
    end

    test "a countdown says which date it counts to instead of pretending to tick" do
      assert {:ok, [{"p", _, [text]}]} =
               VendorMacros.draw("aura-countdown", %{"date" => "2026-12-24"}, [])

      assert text =~ "2026-12-24"
      assert text =~ "cannot tick"
    end
  end

  describe "Adaptavist" do
    test "a tooltip becomes the hint on the content it wraps" do
      assert {:ok, [{"span", attrs, [{"strong", [], ["API"]}]}]} =
               VendorMacros.draw("tooltip", %{"title" => "application programming interface"}, [
                 {"strong", [], ["API"]}
               ])

      assert {"title", "application programming interface"} in attrs
    end

    test "a tooltip with no content shows the hint itself" do
      assert {:ok, [{"span", _, ["a hint"]}]} =
               VendorMacros.draw("tooltip", %{"title" => "a hint"}, [])
    end

    test "a LaTeX block keeps the source and says it is the source" do
      assert {:ok, [{"div", _, [notice, {"pre", [], [source]}]}]} =
               VendorMacros.draw("latex-block", %{}, [{"p", [], ["E = mc^2"]}])

      assert source =~ "E = mc^2"
      assert Floki.text([notice]) =~ "does not typeset"
    end
  end

  describe "Karma" do
    test "a layout element keeps its children in order" do
      assert {:ok, [{"div", [{"class", "mirror-layout karma-row"}], body}]} =
               VendorMacros.draw("karma-row", %{}, [{"p", [], ["left"]}, {"p", [], ["right"]}])

      assert body == [{"p", [], ["left"]}, {"p", [], ["right"]}]
    end
  end
end
