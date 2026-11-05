defmodule ConfluencePhxMirror.SiteUrl do
  @moduledoc """
  One spelling per site, so an address can be a key.

  A token belongs to a site: sending `acme.atlassian.net`'s token to whatever
  address is in a form next is how a secret leaks, and the only defence is that
  a token is never *found* for an address it was not stored for. That makes the
  address a key, and a key has to have one spelling —
  `https://Acme.atlassian.net/wiki/` and `https://acme.atlassian.net/wiki` are
  one site, and two entries in the credential store would be one entry for the
  person and none for the tool.

  Normalisation is therefore conservative: it lower-cases the scheme and the
  host (case never distinguishes them), drops a userinfo (a password in a URL is
  not part of the site's identity, and a key must not carry one), drops the port
  when it is the scheme's own, drops the query and the fragment, and trims the
  trailing slashes from the path. Everything else — the path especially, because
  `https://example.com/confluence` and `https://example.com/jira` are two sites
  — is kept as it was written.

  The scheme may be left out: `acme.atlassian.net` is how a person writes the
  address of a Cloud site, and it names the same site as
  `https://acme.atlassian.net`. It is filled in as https rather than refused,
  because refusing it asks somebody to type four characters that were never in
  doubt.

  `Sites.key_for/1` is a different question: it names *a database*, so it keeps
  the host alone and makes it safe for a filesystem. Two sites under one host
  would collide there and must not here.
  """

  @doc """
  The canonical spelling of `url`, or `nil` when it is not a site address.

  A scheme may be omitted (`acme.atlassian.net`), and `//host/path` is taken as
  https. `nil` is the answer for a blank value, for a scheme that is not http(s)
  (`ftp:`, `mailto:`), and for anything with no host: none of those is an address
  this tool can reach, so none can be the key of a token either.
  """
  @spec normalize(String.t() | nil) :: String.t() | nil
  def normalize(nil), do: nil

  def normalize(url) when is_binary(url) do
    url
    |> String.trim()
    |> with_scheme()
    |> then(fn url -> canonical(URI.parse(url)) end)
  end

  # `acme.example:8443` parses as a scheme called `acme.example` — a bare host
  # with a port is a spelling people type, so a value the first reading cannot
  # make a site of gets a second reading with https in front. Only such a value:
  # `javascript:alert(1)` must not become `https://javascript`.
  defp with_scheme("//" <> _path = url), do: with_scheme("https:" <> url)

  defp with_scheme(url) do
    case canonical(URI.parse(url)) do
      nil -> if host_with_optional_port?(url), do: "https://" <> url, else: url
      _site -> url
    end
  end

  defp host_with_optional_port?(url) do
    case String.split(url, ":", parts: 2) do
      [_host] -> true
      [_host, rest] -> rest |> String.split("/", parts: 2) |> hd() |> only_digits?()
    end
  end

  defp only_digits?(part), do: part != "" and String.match?(part, ~r/\A\d+\z/)

  defp canonical(%URI{scheme: scheme, host: host, port: port, path: path})
       when is_binary(scheme) and is_binary(host) and host != "" do
    scheme = String.downcase(scheme)

    if scheme in ["http", "https"] do
      %URI{
        scheme: scheme,
        host: String.downcase(host),
        port: if(port == URI.default_port(scheme), do: nil, else: port),
        path: trim_path(path)
      }
      |> URI.to_string()
    end
  end

  # No scheme or no host is not a site: `ftp://` is a scheme this tool cannot
  # call, and "" is not an address at all.
  defp canonical(_not_a_site), do: nil
  defp trim_path(nil), do: ""

  defp trim_path(path) do
    trimmed = String.trim_trailing(path, "/")
    if trimmed == "", do: "", else: trimmed
  end

  @doc """
  Whether two addresses name the same site.

  `false` when either is not a site address, including when both are `nil`: two
  absences are not one site, and a caller comparing them is asking about
  something that does not exist.
  """
  @spec same?(String.t() | nil, String.t() | nil) :: boolean()
  def same?(left, right) do
    case {normalize(left), normalize(right)} do
      {nil, _none} -> false
      {_none, nil} -> false
      {same, same} -> true
      {_left, _right} -> false
    end
  end
end
