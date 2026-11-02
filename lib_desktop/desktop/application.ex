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

  alias ConfluencePhxMirror.Desktop.Settings

  @impl true
  def start(_type, _args) do
    # Before the repo: the store resolves its root on use, and the repo reads its
    # path from the settings file as it starts.
    Settings.apply_runtime_config()

    children = [
      ConfluencePhxMirror.Desktop.Repo,
      {Task.Supervisor, name: ConfluencePhxMirror.Desktop.TaskSupervisor}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ConfluencePhxMirror.Desktop.Supervisor
    )
  end
end
