defmodule ConfluencePhxMirror.Sync.Embeds.Vendors do
  @moduledoc """
  The vendors whose player needs an address of its own.

  A *widget connector* stores the address somebody pasted and, beside it, the
  template Confluence would draw it with:

      <ac:parameter ac:name="_template">com/atlassian/confluence/extra/widgetconnector/templates/youtube.vm</ac:parameter>
      <ac:parameter ac:name="overlay">youtube</ac:parameter>
      <ac:parameter ac:name="url"><ri:url ri:value="https://www.youtube.com/watch?v=ii1waoqualY"/></ac:parameter>

  The template is what knows *what the address is*, and for some vendors that
  matters: `youtube.com` refuses to be framed (`X-Frame-Options: sameorigin`) and
  a player is served only from `/embed/`, so framing the address as it was pasted
  gives a reader a blank box. A row here is the difference between a frame and
  nothing.

  A row exists only where the vendor's embed address is documented **and** the
  template name is known: `youtube` is the row this mirror has, and `vimeo`,
  `google`, `twitter` and the rest are absent because their template names are
  not known here. A guessed row draws nothing for everybody.

  Whether a third party may be loaded at all is not this module's question: the
  operator's list in `ConfluencePhxMirror.Sync.Embeds` checks the address this
  module returns, so the *frame's* host is the one that has to be named. A short
  `youtu.be` link therefore needs only `youtube.com`: the frame loads
  `www.youtube.com/embed/…`, and no request reaches the shortener.
  """

  # The hosts a pasted YouTube address may start at. The template says "youtube",
  # so a video on any of them is the same video.
  @youtube_hosts ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]

  # What a YouTube id is made of. Checked because the id is pasted into an
  # address: a value that is not one of these is a parameter worth nothing
  # rather than a video, and it must not be able to change the URL's shape.
  @id ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @vendors ~w(youtube)

  @doc """
  The vendor a widget connector names, or `nil` for one nobody here knows.

      iex> name("com/atlassian/confluence/extra/widgetconnector/templates/youtube.vm", nil)
      "youtube"

      iex> name(nil, "youtube")
      "youtube"

      iex> name("com/atlassian/confluence/extra/widgetconnector/templates/vimeo.vm", "vimeo")
      nil
  """
  @spec name(String.t() | nil, String.t() | nil) :: String.t() | nil
  def name(template, overlay) do
    [template_name(template), known(overlay)]
    |> Enum.find(&is_binary/1)
  end

  @doc """
  The address the frame needs for `vendor`, or `:error` when this address cannot
  be turned into one.

      iex> frame_source("youtube", "https://www.youtube.com/watch?v=ii1waoqualY")
      {:ok, "https://www.youtube.com/embed/ii1waoqualY"}

      iex> frame_source("youtube", "https://youtu.be/ii1waoqualY")
      {:ok, "https://www.youtube.com/embed/ii1waoqualY"}

      iex> frame_source("youtube", "https://www.youtube.com/playlist?list=PL123")
      {:ok, "https://www.youtube.com/embed/videoseries?list=PL123"}

      iex> frame_source("youtube", "https://www.youtube.com/feed/subscriptions")
      :error
  """
  @spec frame_source(String.t(), String.t()) :: {:ok, String.t()} | :error
  def frame_source("youtube", address) when is_binary(address), do: youtube(address)

  defp youtube(address) do
    uri = URI.parse(String.trim(address))
    params = query_params(uri.query)

    case {host(uri), String.split(uri.path || "", "/", trim: true)} do
      {"youtu.be", [id]} -> video(id)
      {host, ["watch"]} when host in @youtube_hosts -> video(params["v"])
      {host, ["embed", "videoseries"]} when host in @youtube_hosts -> playlist(params["list"])
      {host, ["embed", id]} when host in @youtube_hosts -> video(id)
      {host, ["shorts", id]} when host in @youtube_hosts -> video(id)
      {host, ["playlist"]} when host in @youtube_hosts -> playlist(params["list"])
      _another_address -> :error
    end
  end

  defp video(id) when is_binary(id) do
    if Regex.match?(@id, id), do: {:ok, "https://www.youtube.com/embed/" <> id}, else: :error
  end

  defp video(_id), do: :error

  defp playlist(id) when is_binary(id) do
    if Regex.match?(@id, id),
      do: {:ok, "https://www.youtube.com/embed/videoseries?list=" <> id},
      else: :error
  end

  defp playlist(_id), do: :error

  # The query as the page wrote it, undecoded: an id is plain, and a value that
  # is not one of the characters an id is made of is refused rather than decoded
  # into something else.
  defp query_params(query) do
    query
    |> to_string()
    |> String.split("&", trim: true)
    |> Map.new(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [name, value] -> {name, value}
        [name] -> {name, ""}
      end
    end)
  end

  defp host(%URI{host: host}) when is_binary(host) and host != "", do: String.downcase(host)
  defp host(_uri), do: nil

  # `…/templates/youtube.vm` → `youtube`; the template's directory says nothing
  # about the vendor, its file name does.
  defp template_name(template) when is_binary(template) do
    template |> String.split("/") |> List.last() |> String.replace_suffix(".vm", "") |> known()
  end

  defp template_name(_template), do: nil

  defp known(value) when is_binary(value) do
    word = value |> String.trim() |> String.downcase()
    if word in @vendors, do: word
  end

  defp known(_value), do: nil
end
