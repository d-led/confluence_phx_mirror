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

        Mix.shell().error(
          "Either the e-mail/token pair is wrong or the account cannot use Confluence on that site. Confluence said: #{body}"
        )

        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.raise("Probe failed: #{inspect(reason)}")
    end
  end
end
