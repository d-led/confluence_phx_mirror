defmodule ConfluencePhxMirrorWeb.Skins.FreshBlueTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirrorWeb.Skins

  setup do
    %{skin: Skins.get("fresh-blue")}
  end

  test "is the default choice, and one more skin in the picker", %{skin: skin} do
    assert skin.label == "Fresh blue"
    assert skin.custom?
    refute skin.builtin?
    assert skin.selectable?
    assert Skins.default_skin() == "fresh-blue"
  end

  test "paints the light variant by default", %{skin: skin} do
    assert skin.css =~ ~s([data-theme="fresh-blue"]{color-scheme:light)
    assert skin.css =~ "--color-primary:#1565d8"
    assert skin.css =~ "--color-base-100:#ffffff"
  end

  test "paints the dark variant when the OS prefers it", %{skin: skin} do
    assert skin.css =~ "@media (prefers-color-scheme:dark)"
    assert skin.css =~ ~s|{[data-theme="fresh-blue"]{color-scheme:dark|
    assert skin.css =~ "--color-primary:#5c9cf5"
    assert skin.css =~ "--color-base-100:#1c2026"
  end
end
