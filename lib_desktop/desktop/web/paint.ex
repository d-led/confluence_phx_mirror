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

  # Long enough for any path this tool serves, short enough that a report cannot
  # become a page of somebody else's text.
  @path_limit 200

  @doc """
  Records that a window drew `path`.

  The last screen wins: a window that drew the setup form and then the spaces
  list has drawn the spaces list, and that is the one worth reporting.
  """
  @spec drawn(String.t()) :: :ok
  def drawn(path) when is_binary(path) do
    :persistent_term.put(@key, {DateTime.utc_now(), String.slice(path, 0, @path_limit)})
    :ok
  end

  @doc "The last screen a window drew and when, or `nil` if none has."
  @spec last_drawn() :: {DateTime.t(), String.t()} | nil
  def last_drawn, do: :persistent_term.get(@key, nil)

  @doc """
  Forgets what was drawn.

  For tests, which start from nothing the way a freshly opened window does.
  """
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@key)
    :ok
  end
end
