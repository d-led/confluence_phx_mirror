defmodule Mix.Tasks.Confluence.Probe do
  @shortdoc "Checks Confluence base URL and credentials"

  @moduledoc """
  Calls `/rest/api/user/current` with the configured credentials and prints the
  account. Use this before a first real sync:

      CM_SOURCE=http CM_CONFLUENCE_SITE=https://acme.atlassian.net \\
      CM_ATL_EMAIL=you@acme.com CM_ATL_TOKEN=… mix confluence.probe

  A `403 caller cannot access Confluence` means the API token's account has no
  Confluence product access on that site; a `401` means the e-mail/token pair is
  wrong.
  """

  use Mix.Task

  alias ConfluencePhxMirror.Confluence.{HttpSource, Source}

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    if Source.source() != HttpSource do
      Mix.shell().info("""
      The configured source is #{inspect(Source.source())}, so there are no
      Confluence credentials to probe. Re-run with CM_SOURCE=http.
      """)

      exit({:shutdown, 2})
    end

    case HttpSource.probe() do
      {:ok, info} ->
        Mix.shell().info("""
        Connected to #{info.base_url}
        Account: #{info.display_name} <#{info.email}> (#{info.account_id})
        """)

      {:error, :missing_base_url} ->
        Mix.raise("CM_CONFLUENCE_SITE is not set.")

      {:error, {:unauthorized, body}} ->
        Mix.shell().error("Confluence rejected the credentials (HTTP 401).")
        Mix.shell().error("Check CM_ATL_EMAIL and CM_ATL_TOKEN. Confluence said: #{body}")
        exit({:shutdown, 1})

      {:error, {:forbidden, body}} ->
        Mix.shell().error("Confluence refused the call (HTTP 403) for the configured account.")
        Mix.shell().error("Confluence said: #{body}")
        Mix.shell().error(access_hint())
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.raise("Probe failed: #{inspect(reason)}")
    end
  end

  # A 403 from Confluence means the caller reached the site but was refused by
  # it; there are only three ways to get there, so name all three.
  defp access_hint do
    """

    Confluence knows the site but refuses this caller. Check, in this order:

      1. the account can open #{site_url()}/wiki in a browser at all;
      2. the token belongs to that same account (id.atlassian.com -> Security ->
         API tokens lists them per account);
      3. the account holds a Confluence seat on that site, and the
         organisation allows API tokens for Confluence
         (admin.atlassian.com -> Policies).

    An e-mail that does not exist on the site is refused exactly like one
    without a Confluence seat, so a wrong CM_ATL_EMAIL looks identical.
    """
  end

  defp site_url do
    :confluence_phx_mirror
    |> Application.get_env(HttpSource, [])
    |> Keyword.get(:base_url, "https://<site>.atlassian.net")
  end
end
