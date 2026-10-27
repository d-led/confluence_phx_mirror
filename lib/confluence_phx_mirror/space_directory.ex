defmodule ConfluencePhxMirror.SpaceDirectory do
  @moduledoc """
  The spaces the site offers, as it last listed them.

  The screen that adds a space to the whitelist needs a list to choose from, and
  asking Confluence on every render would be both slow and rude. One answer is
  therefore held for a few minutes; `refresh/1` asks again, for the one case
  that matters — a space created a minute ago.

  The list is a convenience, never an authority. A run still asks the source for
  its own listing, so a stale entry can be stale about what to *offer*; it can
  never widen or narrow what is *imported*.

  A failed listing is returned, not cached: a site that was briefly unreachable
  should not look unavailable for the next ten minutes.
  """

  import Cachex.Spec, only: [expiration: 1]

  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror.Space
  alias ConfluencePhxMirror.Sites

  @cache __MODULE__
  @ttl :timer.minutes(10)
  @suggestions 8

  @doc false
  def child_spec(_opts) do
    config = [name: @cache, expiration: expiration(default: @ttl)]
    %{id: __MODULE__, start: {Cachex, :start_link, [config]}, type: :supervisor}
  end

  @doc """
  The spaces the source lists, from the cache when it has them.

  `:source` picks the source for a test; production always uses the configured
  one.
  """
  @spec available(keyword()) :: {:ok, [map()]} | {:error, term()}
  def available(opts \\ []), do: fetch(opts, false)

  @doc "The spaces the source lists, asking it now and replacing what was held."
  @spec refresh(keyword()) :: {:ok, [map()]} | {:error, term()}
  def refresh(opts \\ []), do: fetch(opts, true)

  @doc """
  The spaces worth offering while a key is being typed.

  `term` is matched against the key and the name, in any case, so `load` finds
  `LOAD01` and "Load test". `:excluding` is what the field already names —
  suggesting a key that is already there wastes the reader's eyes — and
  `:limit` is how many a field has room for.

  Personal spaces are never suggested: a mirror does not publish someone's
  private space, so offering one would be offering a mistake.
  """
  @spec suggest(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def suggest(term, opts \\ []) do
    excluding = opts |> Keyword.get(:excluding, []) |> Enum.map(&Space.normalise_key/1)
    limit = Keyword.get(opts, :limit, @suggestions)

    with {:ok, spaces} <- available(Keyword.take(opts, [:source, :type])) do
      {:ok,
       spaces
       |> Enum.reject(&(&1[:type] == "personal" or Space.normalise_key(&1.key) in excluding))
       |> Enum.filter(&matches?(&1, term))
       |> Enum.sort_by(&{String.downcase(&1[:name] || ""), &1.key})
       |> Enum.take(limit)}
    end
  end

  defp matches?(_space, term) when term in [nil, ""], do: true

  defp matches?(space, term) do
    needle = term |> String.trim() |> String.downcase()

    needle == "" or contains?(space.key, needle) or contains?(space[:name], needle)
  end

  defp contains?(nil, _needle), do: false
  defp contains?(text, needle), do: String.contains?(String.downcase(text), needle)

  defp fetch(opts, fresh?) do
    source = Keyword.get(opts, :source) || Source.source()
    key = {source, Sites.url()}

    if fresh?, do: Cachex.del(@cache, key)

    case Cachex.fetch(@cache, key, fn -> read(source, opts) end) do
      {:ok, answer} -> answer
      {:commit, answer} -> answer
      {:ignore, answer} -> answer
      # A cache that is down costs a request, not an answer.
      {:error, _reason} -> ask(source, opts)
    end
  end

  defp read(source, opts) do
    case ask(source, opts) do
      {:ok, spaces} -> {:commit, {:ok, spaces}}
      {:error, reason} -> {:ignore, {:error, reason}}
    end
  end

  defp ask(source, opts), do: source.spaces(Keyword.take(opts, [:type]))
end
