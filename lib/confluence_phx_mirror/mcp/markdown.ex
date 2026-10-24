defmodule ConfluencePhxMirror.Mcp.Markdown do
  @moduledoc """
  Markdown of a mirrored body, converted once per content version.

  `ConfluencePhxMirror.Export.Markdown` parses the page's exported HTML with
  Floki, which is the expensive part of answering a `confluence_get_page` call
  on a long page. A model reading a space asks for the same page more than
  once — once to skim, once to quote — and nothing about the conversion changes
  between those calls, so it is cached.

  The key is the page's local id **and a digest of the body it was converted
  from**. A sync that stores a new body changes the digest, so the next call
  simply misses: there is no invalidation step to forget, and an entry for an
  old revision ages out on its own.

  Comments use the same cache, keyed by `{:comment, id, digest}`: a thread on a
  busy page is asked for as often as the page itself.
  """

  alias ConfluencePhxMirror.Export
  alias ConfluencePhxMirror.Mirror.{Comment, Page}

  # `expiration/1` and `hook/1` build Cachex's configuration records; in Cachex
  # 4 the size bound is a hook (`Cachex.Limit.Scheduled`) rather than an option.
  import Cachex.Spec, only: [expiration: 1, hook: 1]

  @cache __MODULE__
  @limit 10_000
  @ttl :timer.hours(12)

  @doc false
  def child_spec(_opts) do
    config = [
      name: @cache,
      expiration: expiration(default: @ttl),
      hooks: [hook(module: Cachex.Limit.Scheduled, args: {@limit, [], []})]
    ]

    %{id: __MODULE__, start: {Cachex, :start_link, [config]}, type: :supervisor}
  end

  @doc "The page's exported body as Markdown, converted at most once per version."
  @spec page(Page.t()) :: String.t()
  def page(%Page{} = page) do
    cached({page.id, digest(page.body_export)}, page.body_export)
  end

  @doc "A comment's exported body as Markdown, converted at most once per version."
  @spec comment(Comment.t()) :: String.t()
  def comment(%Comment{} = comment) do
    cached({:comment, comment.id, digest(comment.body_export)}, comment.body_export)
  end

  @doc "The key a page's Markdown is stored under. Exposed for tests and metrics."
  @spec page_key(Page.t()) :: tuple()
  def page_key(%Page{} = page), do: {page.id, digest(page.body_export)}

  @doc "Whether a converted body is currently held for this page."
  @spec cached?(Page.t()) :: boolean()
  def cached?(%Page{} = page), do: Cachex.exists?(@cache, page_key(page)) == {:ok, true}

  defp cached(key, html) do
    case Cachex.fetch(@cache, key, fn -> {:commit, Export.Markdown.from_html(html)} end) do
      {:ok, markdown} -> markdown
      {:commit, markdown} -> markdown
      # A cache that is down or full is a slower answer, never a failed one.
      {:error, _reason} -> Export.Markdown.from_html(html)
    end
  end

  # A digest, not the body itself: the key has to stay small however long the
  # page is, and two different bodies must not share an entry.
  defp digest(nil), do: 0
  defp digest(html), do: :erlang.phash2(html)
end
