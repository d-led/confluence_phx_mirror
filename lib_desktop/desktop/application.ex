defmodule ConfluencePhxMirror.Desktop.Application do
  @moduledoc """
  What the export tool starts, and — more to the point — what it does not.

  There is no `Endpoint`, no `Oban`, no `DNSCluster`, no `Presence` and none of
  the catalogue caches. Those exist in the server because many processes share
  one database across several nodes; the tool has one reader, one writer and one
  file, so the machinery would have nothing to coordinate.

  The tree grows one step at a time: the store, and a supervisor to run work
  under. The rate limiter, the traffic budget and the ingest pipeline join it
  when there is something for them to do.
  """

  use Application

  alias ConfluencePhxMirror.Desktop.{Settings, Setup}

  @impl true
  def start(_type, _args) do
    # Before the repo: the store resolves its root on use, and the repo reads its
    # path from here as it starts.
    Settings.apply_runtime_config()

    # A catalogue written by an earlier build cannot be migrated onto the shared
    # schema, and the rename this does cannot happen underneath an open
    # connection — so it happens here, before there is one.
    Setup.prepare(Settings.database())

    children = [
      ConfluencePhxMirror.Repo,
      # Straight after the repo and before anything that queries it: a supervisor
      # starts its children in order, and this one does its work in `start_link`.
      # A fresh install has no tables until it has run.
      ConfluencePhxMirror.Desktop.Setup,
      {Task.Supervisor, name: ConfluencePhxMirror.Desktop.TaskSupervisor},
      # Holds the one mirror run the tool can be doing, so a screen can ask how
      # far along it is.
      ConfluencePhxMirror.Desktop.Jobs,
      # The space list, fetched in the background so no screen waits on it.
      ConfluencePhxMirror.Desktop.Spaces,
      # Last, so the window it advertises is only reachable once the store
      # behind it exists.
      ConfluencePhxMirror.Desktop.Web.Server
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ConfluencePhxMirror.Desktop.Supervisor
    )
  end
end
