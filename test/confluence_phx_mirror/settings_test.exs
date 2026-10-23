defmodule ConfluencePhxMirror.SettingsTest do
  @moduledoc """
  The durable configuration: what an administrator decides outlives the process,
  what they leave alone is exactly what the deployment configured, and a change
  is one transaction or nothing at all.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.{Audit, Settings}

  @actor {:system, "test"}

  setup do
    # The cache outlives a test; start from what the table actually holds.
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

  describe "a setting nobody decided" do
    test "is the deployment's own configuration" do
      assert Settings.stored("reader.html_limit") == nil

      assert Settings.reader_limit(:html) ==
               Application.get_env(:confluence_phx_mirror, :reader_rate_limit)[:html][:limit]

      assert Settings.notifications_enabled?() == true
      assert Settings.digest_hour_utc() == 8
      assert Settings.theme() == Application.get_env(:confluence_phx_mirror, :theme)
    end

    test "follows the configuration when it changes" do
      put_config(:notifications, enabled: false, digest_hour_utc: 5)

      assert Settings.notifications_enabled?() == false
      assert Settings.digest_hour_utc() == 5
    end
  end

  describe "a decision" do
    test "outlives the cache and reads back" do
      assert {:ok, _applied} = Settings.update(%{"reader.html_limit" => "300"}, @actor)

      assert Settings.reader_limit(:html) == 300

      Settings.reload()

      assert Settings.reader_limit(:html) == 300
    end

    test "replaces the deployment's value until it is cleared" do
      Settings.update(%{"notifications.digest_hour_utc" => 3}, @actor)
      assert Settings.digest_hour_utc() == 3

      assert {:ok, _cleared} = Settings.clear(["notifications.digest_hour_utc"], @actor)

      assert Settings.digest_hour_utc() == 8
      assert Settings.stored("notifications.digest_hour_utc") == nil
    end

    test "accepts what a form sends, blank meaning no decision" do
      assert {:ok, %{"notifications.enabled" => false}} =
               Settings.update(%{"notifications.enabled" => "false"}, @actor)

      assert {:ok, %{"reader.api_limit" => nil}} =
               Settings.update(%{"reader.api_limit" => " "}, @actor)

      assert Settings.stored("reader.api_limit") == nil
    end
  end

  describe "a change covering several settings" do
    test "applies all of them and is one audit entry" do
      assert {:ok, applied} =
               Settings.update(
                 %{"reader.html_limit" => "300", "reader.api_limit" => 60},
                 @actor
               )

      assert applied == %{"reader.html_limit" => 300, "reader.api_limit" => 60}
      assert Settings.reader_limit(:html) == 300
      assert Settings.reader_limit(:api) == 60

      assert [%{action: "settings.updated", actor_type: "system", metadata: metadata}] =
               Audit.recent(1)

      assert metadata["changes"] == %{
               "reader.api_limit" => "60",
               "reader.html_limit" => "300"
             }
    end

    test "writes nothing at all when one field cannot be stored" do
      assert {:error, {:invalid_value, "reader.api_limit", "lots"}} =
               Settings.update(
                 %{"reader.html_limit" => "300", "reader.api_limit" => "lots"},
                 @actor
               )

      assert Settings.stored("reader.html_limit") == nil
      assert Settings.reader_limit(:html) == Settings.default("reader.html_limit")
      assert Audit.recent(1) == []
    end

    test "refuses a key this mirror does not know" do
      assert {:error, {:unknown_key, "reader.magic"}} =
               Settings.update(%{"reader.magic" => "1"}, @actor)
    end
  end

  describe "the theme" do
    test "is one of the settings, stored the same way" do
      assert {:ok, _applied} = Settings.put_theme("default", @actor)

      assert Settings.effective("theme") == "default"
      assert Settings.theme() == "default"
    end
  end

  describe "webhook overrides" do
    test "are decisions like any other" do
      assert {:ok, _} = Settings.put_webhook_require_signature(true, @actor)
      assert {:ok, _} = Settings.put_webhook_rate_limit(5, @actor)

      Settings.reload()

      assert Settings.webhook_require_signature()
      assert Settings.webhook_rate_limit() == 5
    end

    test "hand the decision back to the deployment when cleared" do
      Settings.put_webhook_require_signature(true, @actor)
      Settings.put_webhook_require_signature(nil, @actor)

      assert Settings.stored("webhook.require_signature") == nil

      assert Settings.webhook_require_signature() ==
               Application.get_env(:confluence_phx_mirror, :webhooks, [])[:require_signature]
    end
  end

  defp put_config(key, value) do
    previous = Application.fetch_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:confluence_phx_mirror, key, old)
        :error -> Application.delete_env(:confluence_phx_mirror, key)
      end
    end)
  end
end
