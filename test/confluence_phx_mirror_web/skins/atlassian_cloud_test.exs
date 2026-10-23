defmodule ConfluencePhxMirrorWeb.Skins.AtlassianCloudTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirrorWeb.Skins

  setup do
    %{skin: Skins.get("atlassian-cloud")}
  end

  test "is a whole-site skin, not one more choice for readers", %{skin: skin} do
    assert skin.label == "Atlassian Cloud"
    assert skin.custom?
    refute skin.builtin?
    refute skin.selectable?
  end

  test "paints the light variant by default", %{skin: skin} do
    assert skin.css =~ ~s([data-theme="atlassian-cloud"]{color-scheme:light)
    assert skin.css =~ "--color-primary:#0c66e4"
    assert skin.css =~ "--color-base-100:#ffffff"
  end

  test "paints the dark variant when the OS prefers it", %{skin: skin} do
    assert skin.css =~ "@media (prefers-color-scheme:dark)"
    assert skin.css =~ ~s|{[data-theme="atlassian-cloud"]{color-scheme:dark|
    assert skin.css =~ "--color-primary:#579dff"
    assert skin.css =~ "--color-base-100:#1d2125"
  end
end
