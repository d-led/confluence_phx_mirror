defmodule ConfluencePhxMirrorWeb.Skins.FreshBlueTest do
  # `Settings.reload/0` reads the table the suite keeps in a sandbox.
  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirrorWeb.Skins

  setup do
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    %{theme: Skins.get_theme("fresh-blue")}
  end

  test "is the theme the mirror ships with", %{theme: theme} do
    assert theme.label == "Fresh blue"
    assert theme.note != ""
    refute theme.builtin?
    assert Skins.theme() == "fresh-blue"
  end

  test "paints the light palette by default", %{theme: theme} do
    assert theme.css =~ ~s([data-theme="fresh-blue"]{color-scheme:light)
    assert theme.css =~ "--color-primary:#1565d8"
    assert theme.css =~ "--color-base-100:#ffffff"
  end

  test "paints the dark palette when it is forced", %{theme: theme} do
    assert theme.css =~ ~s([data-theme="fresh-blue"][data-scheme="dark"]{color-scheme:dark)
    assert theme.css =~ "--color-primary:#5c9cf5"
    assert theme.css =~ "--color-base-100:#1c2026"
  end

  test "leaves the dark palette to the OS when no variant is forced", %{theme: theme} do
    assert theme.css =~
             ~s|@media (prefers-color-scheme:dark){[data-theme="fresh-blue"]:not([data-scheme])|
  end
end
