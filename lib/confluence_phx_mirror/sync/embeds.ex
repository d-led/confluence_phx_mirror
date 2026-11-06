defmodule ConfluencePhxMirror.Sync.Embeds do
  @moduledoc """
  Which third-party pages the mirror may load inside one of its own.

  A *widget connector* says "show the page at this address", and the address is
  whatever somebody typed into Confluence: a stranger's site, a tracker, a
  `javascript:` URL. The mirror is a copy of other people's pages, so the answer
  is a list an operator writes down rather than a judgement a macro makes:

      CM_EMBED_HOSTS=youtube.com,player.vimeo.com

  Empty by default, which means nothing is embedded anywhere and a widget
  connector is the address itself. Naming a host also covers its subdomains —
  `youtube.com` allows `www.youtube.com` — and the same list builds `frame-src`
  in the content security policy, so the renderer and the policy cannot
  disagree: a host nobody named is not framed, and a frame the renderer wrote is
  not blocked.

  Two questions this does not answer, because they belong elsewhere:
  `Publishing.stranger_reachable?/1` decides whether a reader who never signed
  in may be shown a third party at all (one copy of a body is served to
  everybody, so it is decided at sync time and per space), and `linkable?/1`
  is the narrower question of whether an address may be followed by a reader.
  """

  @app :confluence_phx_mirror

  @doc """
  The hosts an operator allowed, normalised: lower case, no scheme, no `*.`

  `CM_EMBED_HOSTS=" YouTube.com , *.vimeo.com "` is two hosts, in the spelling
  the policy needs:

      iex> hosts()
      ["youtube.com", "vimeo.com"]
  """
  @spec hosts() :: [String.t()]
  def hosts do
    @app
    |> Application.get_env(:embed_hosts, [])
    |> Enum.map(&normalise/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  @doc """
  The `frame-src` sources for the content security policy.

  `'self'` is the caller's to add: this is only what an operator allowed. Each
  host is named twice, once on its own and once for its subdomains, which is the
  same breadth `embeddable?/1` has. Empty when nothing is allowed.
  """
  @spec frame_src() :: [String.t()]
  def frame_src do
    Enum.flat_map(hosts(), &["https://#{&1}", "https://*.#{&1}"])
  end

  @doc """
  The address to put in a frame, when this deployment may embed it.

  `https` only, and only a host an operator named; anything else is `:error` and
  the caller shows the address instead of a frame. With `youtube.com` named:

      iex> embeddable?("https://www.youtube.com/watch?v=abc")
      {:ok, "https://www.youtube.com/watch?v=abc"}

  With nothing named, the same address is not a frame:

      iex> embeddable?("https://www.youtube.com/watch?v=abc")
      :error
  """
  @spec embeddable?(String.t()) :: {:ok, String.t()} | :error
  def embeddable?(address) when is_binary(address) do
    uri = URI.parse(String.trim(address))

    if embeddable_uri?(uri), do: {:ok, URI.to_string(uri)}, else: :error
  end

  def embeddable?(_address), do: :error

  @doc """
  The address a reader may be sent to, when there is one.

  A web address and nothing else: `javascript:` and `data:` are not links, and
  a value with no scheme is not something to guess at.

      iex> linkable?("javascript:alert(1)")
      :error

      iex> linkable?("https://example.com/x")
      {:ok, "https://example.com/x"}
  """
  @spec linkable?(String.t()) :: {:ok, String.t()} | :error
  def linkable?(address) when is_binary(address) do
    uri = URI.parse(String.trim(address))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "",
      do: {:ok, URI.to_string(uri)},
      else: :error
  end

  def linkable?(_address), do: :error

  defp embeddable_uri?(%URI{scheme: "https", host: host}) when is_binary(host),
    do: allowed_host?(String.downcase(host))

  defp embeddable_uri?(_uri), do: false

  defp allowed_host?(host) do
    Enum.any?(hosts(), &(&1 == host or String.ends_with?(host, "." <> &1)))
  end

  defp normalise(host) when is_binary(host) do
    host |> String.trim() |> String.downcase() |> String.trim_leading("*.")
  end

  defp normalise(_host), do: ""
end
