defmodule ConfluencePhxMirror.SettingsTest do
  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.{Audit, Settings}

  setup do
    # The cache outlives a test; start from what the table actually holds.
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  test "stores the site skin and records who set it" do
    assert :ok = Settings.put_site_skin("fresh-blue", {:system, "test"})

    assert Settings.site_skin() == "fresh-blue"
    assert [%{action: "settings.site_skin", actor_type: "system"}] = Audit.recent(1)
  end

  test "an empty value clears it" do
    Settings.put_site_skin("fresh-blue", {:system, "test"})
    Settings.put_site_skin("", {:system, "test"})

    assert Settings.site_skin() == nil
  end

  test "a reload picks up what the table holds" do
    Settings.put_site_skin("fresh-blue", {:system, "test"})
    Settings.reload()

    assert Settings.site_skin() == "fresh-blue"
  end
end
