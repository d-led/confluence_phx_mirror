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

  describe "webhook overrides" do
    test "an administrator's decision outlives the cache and reads back" do
      :ok = Settings.put_webhook_require_signature(true, {:system, "test"})
      :ok = Settings.put_webhook_rate_limit(5, {:system, "test"})

      Settings.reload()

      assert Settings.webhook_require_signature()
      assert Settings.webhook_rate_limit() == 5
    end

    test "clearing a decision hands it back to the deployment" do
      Settings.put_webhook_require_signature(true, {:system, "test"})
      Settings.put_webhook_require_signature(nil, {:system, "test"})

      assert Settings.webhook_require_signature() == nil
    end

    test "a setting nobody touched reads as no decision at all" do
      assert Settings.webhook_rate_limit() == nil
      assert Settings.webhook_require_signature() == nil
    end

    test "the change is audited with the value that was chosen" do
      Settings.put_webhook_require_signature(false, {:system, "test"})

      assert [%{action: "settings.webhook_signature", metadata: metadata}] = Audit.recent(1)
      assert metadata["required"] == false
    end
  end
end
