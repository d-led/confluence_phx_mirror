defmodule ConfluencePhxMirrorWeb.Admin.Settings do
  @moduledoc """
  What this mirror booted with, grouped for the admin settings page.

  Everything here is read from the application environment when the page is
  requested, and those values were fixed at boot — which is why the page is a
  static controller and not a LiveView: nothing on it can change while you look
  at it. Each row names the environment variable that changes it.

  Secrets are reported as present or absent and never printed: the page says
  whether a webhook secret is configured, not what it is.
  """

  alias ConfluencePhxMirror.Confluence.{HttpSource, Source}
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirrorWeb.Skins

  @type row :: %{label: String.t(), value: String.t(), env: String.t() | nil}
  @type section :: %{title: String.t(), rows: [row()]}

  @doc """
  The configuration, in the order an operator usually needs it: what is being
  mirrored, how it looks, who may administer it, where it sends things, and the
  limits it enforces.
  """
  @spec sections(map() | nil) :: [section()]
  def sections(user \\ nil) do
    [source(), appearance(), access(user), delivery(), limits()]
  end

  defp source do
    http = Application.get_env(:confluence_phx_mirror, HttpSource, [])

    %{
      title: "Source & sync",
      rows: [
        row("Source", source_label(Source.source()), "CM_SOURCE"),
        row("Site", Sites.url() || "—", "CM_CONFLUENCE_SITE"),
        row("Spaces", spaces(http[:spaces]), "CM_SPACES"),
        row("Sync interval", every(http[:sync_interval_seconds]), "CM_SYNC_INTERVAL_SECONDS"),
        row("Sync concurrency", count(http[:sync_concurrency]), "CM_SYNC_CONCURRENCY"),
        row("Requests per second", count(http[:requests_per_second]), "CM_REQUESTS_PER_SECOND"),
        row("Burst", count(http[:burst]), "CM_BURST"),
        row("Page size", count(http[:page_size]), "CM_HTTP_PAGE_SIZE")
      ]
    }
  end

  defp appearance do
    %{
      title: "Appearance",
      rows: [
        row("Default skin", Skins.default_skin(), "CM_DEFAULT_SKIN"),
        row("Reader picker", picker(), nil),
        row("Skins offered", Enum.map_join(Skins.all(), ", ", & &1.name), nil),
        row("Site skin", Skins.site_skin() || "off — readers choose", "CM_SITE_SKIN")
      ]
    }
  end

  defp access(user) do
    %{
      title: "Access",
      rows: [
        row("Signed in as", signed_in(user), nil),
        row("Administrators", joined(config(:admins)), "CM_ADMINS"),
        row("Admin groups", joined(config(:admin_groups)), "CM_ADMIN_GROUPS"),
        row("Proxy identity", proxy(), "CM_PROXY_AUTH"),
        row("Automatic sign-in", toggle(config(:auto_admin)), "MIRROR_AUTO_ADMIN"),
        row("Self sign-up", toggle(config(:self_signup)), "MIRROR_SELF_SIGNUP")
      ]
    }
  end

  defp delivery do
    webhooks = config(:webhooks, [])
    notifications = config(:notifications, [])

    %{
      title: "Delivery",
      rows: [
        row(
          "Webhook secret",
          if(webhooks[:secret], do: "configured", else: "not set"),
          "CM_WEBHOOK_SECRET"
        ),
        row(
          "Signature required",
          toggle(webhooks[:require_signature] != false),
          "CM_WEBHOOK_REQUIRE_SIGNATURE"
        ),
        row("Webhook tokens", receivers(config(:webhook_tokens, %{})), "CM_WEBHOOK_TOKENS"),
        row("Notifications", toggle(notifications[:enabled]), "MIRROR_NOTIFICATIONS"),
        row("Mail from", mail_from(notifications[:from]), "MIRROR_MAIL_FROM"),
        row(
          "Digest hour (UTC)",
          hour(notifications[:digest_hour_utc]),
          "MIRROR_DIGEST_HOUR_UTC"
        )
      ]
    }
  end

  defp limits do
    reader = config(:reader_rate_limit, [])

    %{
      title: "Limits & storage",
      rows: [
        row("Readers (HTML)", per_minute(reader[:html]), "CM_READER_RATE_LIMIT_PER_MINUTE"),
        row("Readers (API)", per_minute(reader[:api]), "CM_RATE_LIMIT_API_PER_MINUTE"),
        row(
          "Readers (attachments)",
          per_minute(reader[:attachments]),
          "CM_RATE_LIMIT_ATTACHMENTS_PER_MINUTE"
        ),
        row(
          "Webhook intake",
          per_minute(config(:webhook_rate_limit)),
          "CM_WEBHOOK_RATE_LIMIT_PER_MINUTE"
        ),
        row(
          "Trust proxy headers",
          toggle(config(:trust_proxy_headers)),
          "CM_TRUST_PROXY_HEADERS"
        ),
        row("Blob root", to_string(config(:blob_root, "var/mirror")), "MIRROR_BLOB_ROOT")
      ]
    }
  end

  defp row(label, value, env), do: %{label: label, value: value, env: env}

  defp config(key, default \\ nil),
    do: Application.get_env(:confluence_phx_mirror, key, default)

  defp source_label(module) do
    case Source.kind(module) do
      :demo -> "Bundled demo snapshot"
      _live -> "Confluence REST API"
    end
  end

  defp spaces(:all), do: "all spaces"
  defp spaces(keys) when is_list(keys), do: Enum.join(keys, ", ")
  defp spaces(_keys), do: "—"

  defp every(nil), do: "—"

  defp every(seconds) when seconds >= 3600 and rem(seconds, 3600) == 0,
    do: "every #{div(seconds, 3600)} h"

  defp every(seconds) when seconds >= 60 and rem(seconds, 60) == 0,
    do: "every #{div(seconds, 60)} min"

  defp every(seconds), do: "every #{seconds} s"

  defp hour(nil), do: "—"
  defp hour(hour), do: String.pad_leading(to_string(hour), 2, "0") <> ":00"

  defp count(nil), do: "—"
  defp count(value), do: to_string(value)

  defp picker do
    if Skins.site_skin() do
      "hidden — one skin for every reader"
    else
      "#{length(Skins.reader_skins())} skins"
    end
  end

  defp signed_in(nil), do: "anonymous"

  defp signed_in(user) do
    case user do
      %{email: email} -> to_string(email)
      _user -> "signed in"
    end
  end

  defp joined([]), do: "—"
  defp joined(nil), do: "—"
  defp joined(values), do: Enum.join(values, ", ")

  defp proxy do
    if config(:proxy_auth, false) do
      "on (#{config(:proxy_auth_header, "x-forwarded-email")})"
    else
      "off"
    end
  end

  defp toggle(true), do: "on"
  defp toggle(_value), do: "off"

  defp receivers(tokens) when is_map(tokens) and map_size(tokens) > 0,
    do: "#{map_size(tokens)} configured"

  defp receivers(_tokens), do: "none"

  defp mail_from({name, address}), do: "#{name} <#{address}>"
  defp mail_from(nil), do: "—"
  defp mail_from(address), do: to_string(address)

  defp per_minute(nil), do: "unlimited"

  defp per_minute(settings) when is_list(settings) do
    case Keyword.get(settings, :limit) do
      limit when is_integer(limit) and limit > 0 -> "#{limit}/min"
      _unlimited -> "unlimited"
    end
  end

  defp per_minute(_settings), do: "unlimited"
end
