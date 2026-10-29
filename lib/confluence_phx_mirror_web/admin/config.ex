defmodule ConfluencePhxMirrorWeb.Admin.Config do
  @moduledoc """
  The configuration this mirror *booted* with, grouped for the settings page.

  What an administrator can change while the mirror runs lives in
  `ConfluencePhxMirror.Settings` and is edited above this block; everything
  listed here is read from the application environment and settles at boot.
  Each row names the variable that sets it, so the page answers "where does this
  come from?" without a trip through the config files.

  Secrets are reported as present or absent and never printed: the page says
  whether a webhook secret is configured, not what it is.
  """

  alias ConfluencePhxMirror.Confluence.{HttpSource, Source}
  alias ConfluencePhxMirror.Sites

  @type row :: %{label: String.t(), value: String.t(), env: String.t() | nil}
  @type section :: %{title: String.t(), rows: [row()]}

  @doc """
  The configuration, in the order an operator usually needs it: what is being
  mirrored, who may administer it, where it sends things, and where the content
  and the proxy sit.
  """
  @spec sections(map() | nil) :: [section()]
  def sections(user \\ nil) do
    [source(), access(user), delivery(), limits()]
  end

  defp source do
    http = Application.get_env(:confluence_phx_mirror, HttpSource, [])

    %{
      title: "Source & sync",
      rows: [
        row("Source", source_label(Source.source()), "CM_SOURCE"),
        row("Site", Sites.url() || "—", "CM_CONFLUENCE_SITE"),
        row("Spaces", spaces(http[:spaces]), "CM_SPACES"),
        row(
          "Personal spaces",
          if(config(:sync, [])[:personal_spaces], do: "mirrored", else: "skipped"),
          "CM_SYNC_PERSONAL_SPACES"
        ),
        row("Requests per second", count(http[:requests_per_second]), "CM_REQUESTS_PER_SECOND"),
        row("Burst", count(http[:burst]), "CM_BURST")
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
        row("Self sign-up", toggle(config(:self_signup)), "MIRROR_SELF_SIGNUP"),
        row(
          "Site-disabled readers",
          if(config(:allow_site_disabled_readers, false),
            do: "admitted",
            else: "refused (the site decides)"
          ),
          "MIRROR_ALLOW_SITE_DISABLED_READERS"
        )
      ]
    }
  end

  defp delivery do
    webhooks = config(:webhooks, [])

    %{
      title: "Delivery",
      rows: [
        row(
          "Webhook secret",
          if(webhooks[:secret], do: "configured", else: "not set"),
          "CM_WEBHOOK_SECRET"
        ),
        row(
          "Webhook intake",
          if(webhooks[:enabled] == false, do: "off (404, as if unrouted)", else: "accepting"),
          "CM_WEBHOOK_ENABLED"
        ),
        row("Webhook tokens", receivers(config(:webhook_tokens, %{})), "CM_WEBHOOK_TOKENS")
      ]
    }
  end

  defp limits do
    %{
      title: "Storage & proxy",
      rows: [
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

  defp count(nil), do: "—"
  defp count(value), do: to_string(value)

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
end
