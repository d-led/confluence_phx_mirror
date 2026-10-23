defmodule ConfluencePhxMirror.SettingsTest do
  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.{Audit, Settings}

  setup do
    # The cache outlives a test; start from what the table actually holds.
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "stores the theme and records who set it" do
    assert :ok = Settings.put_theme("default", {:system, "test"})

    assert Settings.theme() == "default"
    assert [%{action: "settings.theme", actor_type: "system"}] = Audit.recent(1)
  end

  test "an empty value clears it" do
    Settings.put_theme("default", {:system, "test"})
    Settings.put_theme("", {:system, "test"})

    assert Settings.theme() == nil
  end

  test "a reload picks up what the table holds" do
    Settings.put_theme("default", {:system, "test"})
    Settings.reload()

    assert Settings.theme() == "default"
  end
end
