defmodule ConfluencePhxMirror.Desktop.Web.Paint do
  @moduledoc """
  The last screen a window drew, if it drew one at all.

  Everything this build has ever been asked in a test was asked without a window:
  `curl` fetches HTML, and a server that serves a page has not thereby drawn it.
  That gap is not theoretical — the window once judged its own splash page an
  outside link, opened a console and a browser instead of the tool, and every
  server-level check still passed, because the server was fine.

  So the tool's pages say so. Every screen under `/__tool` carries one line of
  script that reports the path it drew, and only a window runs a page's script.
  A test that starts the real executable can then tell "the window opened and
  painted the setup screen" from "a server started and nobody looked".
  """

  @key {__MODULE__, :drawn}

  # Long enough for any label this tool prints, short enough that a report cannot
  # become a page of somebody else's text.
  @text_limit 200

  @typedoc """
  What a window reported, and not only where it was.

  A path alone would let a window that drew an empty page pass: `/` is the setup
  form on a fresh workspace and the mirror's home on a configured one. `fields`
  are the form boxes with a visible rectangle — the things a person types into —
  and not the hidden inputs a page keeps for its own script.
  """
  @type report :: %{
          required(:at) => DateTime.t(),
          required(:path) => String.t(),
          required(:title) => String.t(),
          required(:heading) => String.t(),
          required(:fields) => [String.t()],
          required(:button) => String.t()
        }

  @doc """
  Records what a window drew.

  The last screen wins: a window that drew the setup form and then the spaces
  list has drawn the spaces list, and that is the one worth reporting.
  """
  @spec drawn(map()) :: :ok
  def drawn(seen) when is_map(seen) do
    :persistent_term.put(@key, Map.put(normalize(seen), :at, DateTime.utc_now()))
    :ok
  end

  @doc "What the last window saw, or `nil` if no window has drawn a screen."
  @spec last_drawn() :: report() | nil
  def last_drawn, do: :persistent_term.get(@key, nil)

  @doc """
  The report as one fact per line, for whatever started the window.

  Lines rather than JSON because the reader is a shell: a smoke test greps for
  `fields: …site…`, and a person reading a CI log reads the same lines.
  """
  @spec describe(report()) :: String.t()
  def describe(%{at: at} = seen) do
    """
    painted #{seen.path} at #{DateTime.to_iso8601(at)}
    title: #{seen.title}
    heading: #{seen.heading}
    fields: #{Enum.join(seen.fields, ",")}
    button: #{seen.button}
    """
  end

  @doc """
  Forgets what was drawn.

  For tests, which start from nothing the way a freshly opened window does.
  """
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@key)
    :ok
  end

  # A window's words are clamped and trimmed, not trusted: the report is printed
  # in a log and rendered in another page's answer, and neither is a place for an
  # unbounded string.
  defp normalize(seen) do
    %{
      path: path(Map.get(seen, :path)),
      title: text(Map.get(seen, :title)),
      heading: text(Map.get(seen, :heading)),
      fields: seen |> Map.get(:fields, []) |> Enum.map(&text/1) |> Enum.reject(&(&1 == "")),
      button: text(Map.get(seen, :button))
    }
  end

  defp path(nil), do: "/"

  defp path(value) do
    case text(value) do
      "" -> "/"
      path -> path
    end
  end

  defp text(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, @text_limit)

  defp text(_value), do: ""
end
