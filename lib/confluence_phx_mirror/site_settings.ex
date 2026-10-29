defmodule ConfluencePhxMirror.SiteSettings do
  @moduledoc """
  What the site says about *itself*, and how much of it this mirror uses.

  Confluence's General configuration has two halves. The half that reaches a
  mirror through the content needs no table here — a space's icon, a page's
  width and every date inside a body arrive already rendered. The half about the
  site is what this module keeps: the title it goes by, the language a reader is
  defaulted to, and its time zone, read once per run through
  `ConfluencePhxMirror.Confluence.Source.site_settings/1`.

  **What is not here is as important as what is.** Confluence Cloud exposes only
  a corner of that screen over REST — the admin page reads its own values over
  GraphQL with a browser session — so the landing page, the page width, the date
  and number formats, the attachment cap and the presence switch cannot be
  synced. Those are the mirror's own settings, and the guide says so where an
  operator would look for them.

  A run that cannot read them changes nothing: an unreachable settings endpoint
  is not a reason to fail a sync, and a site that has no opinion is not a site
  that turned its title off.

  ## Reads never touch the database

  The row is one, and every page a reader opens asks it for the document's
  language: `load/0` fills `:persistent_term` at boot, and `put/1` refreshes it
  after the write. The same trade `ConfluencePhxMirror.Settings` makes.
  """

  alias ConfluencePhxMirror.{Audit, Repo}
  alias ConfluencePhxMirror.Audit.Entry
  alias ConfluencePhxMirror.SiteSettings.Setting

  @id 1
  @term {__MODULE__, :current}

  @doc "The row as last read, or `nil` when no source has ever said."
  @spec current() :: Setting.t() | nil
  def current, do: :persistent_term.get(@term, nil)

  @doc """
  Reads the row into memory. Called once, after the repository is up, so the
  request path never asks the table what language the site is written in.
  """
  @spec load() :: :ok
  def load do
    :persistent_term.put(@term, Repo.get(Setting, @id))
    :ok
  end

  @doc """
  Drops the cached row without reading the table.

  `:persistent_term` survives a rolled-back test transaction, so the suite
  forgets between tests rather than leaving one test's site to the next.
  """
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@term)
    :ok
  end

  @doc "The site's title, or `nil`."
  @spec title() :: String.t() | nil
  def title, do: current() |> field(:title)

  @doc """
  The language a reader is defaulted to, as an HTML language tag.

  Confluence spells it the Java way (`en_GB`); a document says `en-GB`.
  """
  @spec lang() :: String.t() | nil
  def lang, do: current() |> field(:locale) |> lang_tag()

  @doc "The site's time zone, or `nil`. Stored for what is rendered outside a browser."
  @spec timezone() :: String.t() | nil
  def timezone, do: current() |> field(:timezone)

  @doc "A locale in Confluence's spelling, as a language tag."
  @spec lang_tag(String.t() | nil) :: String.t() | nil
  def lang_tag(nil), do: nil

  def lang_tag(locale) when is_binary(locale) do
    case locale |> String.trim() |> String.replace("_", "-") do
      "" -> nil
      tag -> tag
    end
  end

  @doc """
  Stores what the site said.

  Returns `:changed` only when something a reader could notice is different — a
  run every hour must not fill the audit log with "still the same" — and `:ok`
  otherwise, including when the site said exactly what the row already carried.

  A write asks the table, not the cache, whether there is a row to update: what
  is in memory answers reads, and a run must not insert over a row it never saw.
  """
  @spec put(map()) :: :ok | :changed
  def put(settings) when is_map(settings) do
    attrs = %{
      title: blank(settings[:title]),
      locale: blank(settings[:locale]),
      timezone: blank(settings[:timezone]),
      fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case Repo.get(Setting, @id) do
      nil -> insert(attrs)
      %Setting{} = row -> update(row, attrs)
    end
  end

  defp insert(attrs) do
    case %Setting{id: @id} |> Setting.changeset(attrs) |> Repo.insert() do
      {:ok, row} ->
        :persistent_term.put(@term, row)
        audited(attrs)

      # The only way this fails is a missing timestamp, which `put/1` always
      # sets: there is nothing for a caller to do, and a run must not fail
      # because a title did not fit.
      {:error, _changeset} ->
        :ok
    end
  end

  defp update(%Setting{} = row, attrs) do
    if same?(row, attrs) do
      :ok
    else
      :persistent_term.put(@term, Repo.update!(Setting.changeset(row, attrs)))
      audited(attrs)
    end
  end

  # `fetched_at` moves on every read; it is not something a reader notices, so
  # it is not part of "the site changed".
  defp same?(row, attrs) do
    row.title == attrs.title and row.locale == attrs.locale and row.timezone == attrs.timezone
  end

  defp audited(attrs) do
    Audit.log(
      Audit.system_actor(),
      Entry.new("site.settings_read", "site_settings", @id, %{
        "title" => attrs.title,
        "locale" => attrs.locale,
        "timezone" => attrs.timezone
      })
    )

    :changed
  end

  defp field(nil, _key), do: nil
  defp field(%Setting{} = row, key), do: Map.get(row, key)

  defp blank(nil), do: nil

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
