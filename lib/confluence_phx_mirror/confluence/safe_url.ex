defmodule ConfluencePhxMirror.Confluence.SafeURL do
  @moduledoc """
  SSRF guard for everything the HTTP source fetches.

  The mirror must only ever talk to the configured Confluence site. Redirects
  are never followed and pagination links are validated with the same rules, so
  a compromised or malicious response cannot make the server fetch internal
  addresses.
  """

  @max_length 2_048

  @type reason ::
          :invalid_url
          | :unsupported_scheme
          | :missing_host
          | :userinfo_not_allowed
          | :url_too_long
          | :host_not_allowed

  @doc "Validates `url` against the origin of `base_url`."
  @spec validate(String.t() | nil, String.t() | nil) :: {:ok, URI.t()} | {:error, reason()}
  def validate(url, base_url) do
    with {:ok, base} <- base_uri(base_url),
         {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri),
         :ok <- check_host(uri, base) do
      {:ok, uri}
    end
  end

  @doc """
  Absolute URL string for `path`, relative to `base_url`.

  Accepts an absolute URL (validated as-is) or a path that starts with `/`,
  which is completed with the base URL's origin first. Confluence's
  `_links.download` is relative, so downloads rely on this.
  """
  def resolve(path, base_url) do
    with {:ok, base} <- base_uri(base_url),
         {:ok, absolute} <- absolute(path, base),
         {:ok, uri} <- validate(absolute, base_url) do
      {:ok, URI.to_string(uri)}
    end
  end

  # `//host/path` is scheme-relative and must not be completed with our origin.
  defp absolute(path, base) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"),
      do: {:ok, origin(base) <> path},
      else: {:ok, path}
  end

  defp absolute(path, _base), do: parse(path)

  defp origin(%URI{scheme: scheme, host: host, port: port}) do
    %URI{scheme: scheme, host: host, port: port} |> URI.to_string()
  end

  defp base_uri(nil), do: {:error, :host_not_allowed}

  defp base_uri(base_url) do
    case parse(base_url) do
      {:ok, uri} -> {:ok, uri}
      error -> error
    end
  end

  defp parse(nil), do: {:error, :invalid_url}

  defp parse(url) when is_binary(url) do
    if byte_size(url) > @max_length do
      {:error, :url_too_long}
    else
      uri = URI.parse(url)
      if is_binary(uri.host) and uri.host != "", do: {:ok, uri}, else: {:error, :missing_host}
    end
  end

  defp parse(_url), do: {:error, :invalid_url}

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok
  defp check_scheme(_uri), do: {:error, :unsupported_scheme}

  defp check_host(%URI{userinfo: userinfo}, _base) when is_binary(userinfo) and userinfo != "" do
    {:error, :userinfo_not_allowed}
  end

  defp check_host(%URI{host: host}, %URI{host: base_host}) do
    if String.downcase(host) == String.downcase(base_host) do
      :ok
    else
      {:error, :host_not_allowed}
    end
  end
end
