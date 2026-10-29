defmodule ConfluencePhxMirror.SettingsTest do
  @moduledoc """
  The durable configuration: what an administrator decides outlives the process,
  what they leave alone is exactly what the deployment configured, and a change
  is one transaction or nothing at all.
  """

  use ConfluencePhxMirror.DataCase, async: false

  @moduletag :empty_mirror

  alias ConfluencePhxMirror.{Accounts, Audit, Settings}
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.TestConfig

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
      TestConfig.put(:notifications, enabled: false, digest_hour_utc: 5)

      assert Settings.notifications_enabled?() == false
      assert Settings.digest_hour_utc() == 5
    end
  end

  describe "the page a reader lands on" do
    test "is the mirror's own home until an administrator chooses" do
      assert Settings.landing_page() == "home"
    end

    test "can be the space directory" do
      assert {:ok, _applied} = Settings.update(%{"site.landing_page" => "spaces"}, @actor)

      assert Settings.landing_page() == "spaces"
    end

    test "refuses a page this mirror does not have" do
      assert {:error, {:invalid_value, "site.landing_page", "nowhere"}} =
               Settings.update(%{"site.landing_page" => "nowhere"}, @actor)

      assert Settings.landing_page() == "home"
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

  describe "a setting declared after the first release" do
    test "takes its default from the deployment's configuration" do
      TestConfig.put(:search, page_size: 12, default_limit: 7, max_limit: 50)

      assert Settings.search_page_size() == 12
      assert Settings.search_default_limit() == 7
      assert Settings.search_max_results() == 50
    end

    test "is what the code that cares reads, once somebody stored it" do
      assert {:ok, _applied} =
               Settings.update(%{"accounts.login_token_minutes" => "45"}, @actor)

      assert Accounts.login_token_minutes() == 45
    end
  end

  describe "the mail server" do
    # A stored relay rewrites the application environment the mailer reads — it is
    # global, and a later test that mails would reach for a relay that is not
    # there. So the deployment's own configuration is put back, value for value,
    # rather than recomputed from a table the sandbox may not have rolled back.
    setup do
      # `TestConfig` is the only door to the application environment in the suite:
      # it remembers the deployment's value once and puts it back afterwards.
      TestConfig.put(
        ConfluencePhxMirror.Mailer,
        Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Mailer, [])
      )

      # The sender is published into the notifications config as well, so that
      # one is put back here too.
      TestConfig.put(:notifications, Application.get_env(:confluence_phx_mirror, :notifications))

      on_exit(fn -> Settings.forget() end)
      :ok
    end

    test "is the deployment's until an administrator stores one" do
      assert Settings.mail_configuration() ==
               Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Mailer, [])
    end

    test "a stored relay sends through SMTP, with the values stored beside it" do
      {:ok, _applied} =
        Settings.update(
          %{
            "mail.relay" => "smtp.example.com",
            "mail.port" => "2525",
            "mail.tls" => "never",
            "mail.auth" => "never"
          },
          @actor
        )

      config = Settings.mail_configuration()

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 2525
      assert config[:tls] == :never
      assert config[:auth] == :never
    end

    test "the save is what puts the stored server in force" do
      {:ok, _applied} = Settings.update(%{"mail.relay" => "smtp.example.com"}, @actor)

      assert Application.get_env(:confluence_phx_mirror, ConfluencePhxMirror.Mailer)[:relay] ==
               "smtp.example.com"
    end

    # A relay behind a cross-signed chain — Brevo's is one — is refused by OTP's
    # own defaults however good its certificate is, so the connection is told
    # what to verify.
    test "the connection verifies the relay's certificate, against the relay's name" do
      {:ok, _applied} = Settings.update(%{"mail.relay" => "smtp-relay.brevo.com"}, @actor)

      options = Settings.mail_configuration()[:tls_options]

      assert options[:verify] == :verify_peer
      assert options[:server_name_indication] == ~c"smtp-relay.brevo.com"
      assert options[:cacerts] != []
    end

    test "is from the deployment's sender until an administrator stores one" do
      assert Settings.mail_sender() == Application.get_env(:confluence_phx_mirror, :mail_from)
    end

    test "a stored sender is the one mail is from, and clearing hands it back" do
      {:ok, _applied} =
        Settings.update(
          %{"mail.from" => "mirror@acme.example", "mail.from_name" => "Acme Mirror"},
          @actor
        )

      assert Settings.mail_sender() == {"Acme Mirror", "mirror@acme.example"}

      # The builders that read the notifications config get the same answer, so
      # a message cannot disagree with this screen about who it is from.
      assert Application.get_env(:confluence_phx_mirror, :notifications)[:from] ==
               {"Acme Mirror", "mirror@acme.example"}

      {:ok, _cleared} = Settings.clear(["mail.from", "mail.from_name"], @actor)

      assert Settings.mail_sender() == Application.get_env(:confluence_phx_mirror, :mail_from)

      assert Application.get_env(:confluence_phx_mirror, :notifications)[:from] ==
               Application.get_env(:confluence_phx_mirror, :mail_from)
    end
  end

  describe "the cadence and the calls a run makes" do
    test "come from the deployment when nobody decided" do
      merge_config(Source.source(), sync_interval_seconds: 900, page_size: 25)

      assert Settings.sync_interval_seconds() == 900
      assert Settings.confluence_page_size() == 25
    end

    test "are the administrator's once they decided" do
      assert {:ok, _applied} =
               Settings.update(
                 %{"sync.interval_seconds" => "1800", "confluence.page_size" => "100"},
                 @actor
               )

      assert Settings.sync_interval_seconds() == 1800
      assert Settings.confluence_page_size() == 100
    end

    test "can switch the missing-pages pass off, which is what 0 means" do
      merge_config(Source.source(), reconcile_interval_seconds: 86_400)
      assert Settings.reconcile_interval_seconds() == 86_400

      assert {:ok, %{"sync.reconcile_interval_seconds" => 0}} =
               Settings.update(%{"sync.reconcile_interval_seconds" => "0"}, @actor)

      assert Settings.reconcile_interval_seconds() == 0
    end

    test "refuse a cadence that is not a number" do
      assert {:error, {:invalid_value, "sync.interval_seconds", "soon"}} =
               Settings.update(%{"sync.interval_seconds" => "soon"}, @actor)
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

  describe "a value that cannot be a setting" do
    test "is refused by its declared type, and nothing is written" do
      refused = [
        {"reader.html_limit", "0"},
        {"reader.html_limit", "-3"},
        {"reader.html_limit", "lots"},
        {"notifications.digest_hour_utc", "24"},
        {"notifications.digest_hour_utc", "-1"},
        {"notifications.enabled", "maybe"},
        {"theme", 42}
      ]

      for {key, value} <- refused do
        assert {:error, {:invalid_value, ^key, ^value}} =
                 Settings.update(%{key => value}, @actor),
               "#{key} accepted #{inspect(value)}"
      end

      assert Settings.stored("reader.html_limit") == nil
      assert Audit.recent(1) == []
    end

    test "is ignored when it is already in the table, and the deployment's value applies" do
      ConfluencePhxMirror.Repo.insert!(%ConfluencePhxMirror.Settings.Setting{
        key: "reader.html_limit",
        value: "lots"
      })

      log = ExUnit.CaptureLog.capture_log(fn -> Settings.reload() end)

      assert log =~ "unreadable setting reader.html_limit"
      assert Settings.stored("reader.html_limit") == nil
      assert Settings.reader_limit(:html) == Settings.default("reader.html_limit")
    end
  end

  describe "a list setting" do
    test "keeps the keys it names, without the repetition or the spaces around them" do
      assert {:ok, %{"sync.spaces" => ["ENG", "PROD"]}} =
               Settings.update(%{"sync.spaces" => "ENG, PROD ,ENG"}, @actor)

      assert Settings.wanted_spaces() == ["ENG", "PROD"]
    end

    test "cleared, it adds nothing at all" do
      Settings.update(%{"sync.spaces" => "ENG"}, @actor)

      assert {:ok, _cleared} = Settings.update(%{"sync.spaces" => "  "}, @actor)

      assert Settings.wanted_spaces() == []
      assert Settings.stored("sync.spaces") == nil
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

    test "close an intake the deployment leaves open" do
      TestConfig.put(:webhooks, enabled: true, secret: "the-secret")

      assert Settings.webhook_enabled?()
      assert {:ok, _} = Settings.put_webhook_enabled(false, @actor)
      refute Settings.webhook_enabled?()

      assert {:ok, _} = Settings.put_webhook_enabled(nil, @actor)
      assert Settings.webhook_enabled?()
    end
  end

  # A source has options this test does not care about, so it widens the list
  # instead of replacing it.
  defp merge_config(key, value) do
    TestConfig.put(
      key,
      Keyword.merge(Application.get_env(:confluence_phx_mirror, key, []), value)
    )
  end
end
