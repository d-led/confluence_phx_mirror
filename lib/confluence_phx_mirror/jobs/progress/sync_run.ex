defimpl ConfluencePhxMirror.Jobs.Progress, for: ConfluencePhxMirror.Sync.SyncRun do
  # A verified path: a record that names its log should break the build, not the
  # link, when the route moves.
  use Phoenix.VerifiedRoutes,
    endpoint: ConfluencePhxMirrorWeb.Endpoint,
    router: ConfluencePhxMirrorWeb.Router

  @moduledoc """
  A sync run reports itself the way the overview's table reads it: the counters
  are the run's window over the site, not the mirror's size.

  The state is the run's own `status`, which already distinguishes a run that
  finished cleanly from one that ended with page errors (`partial`) — the tone
  says which of those an operator should look at. Its log is the sync log,
  narrowed to this run.
  """

  alias ConfluencePhxMirror.Sync.SyncRun

  @impl true
  def state(%SyncRun{status: status}), do: {status, tone(status)}

  @impl true
  # What the run has done so far, in the same numbers the dashboard prints: a
  # running job is a run whose counters still move, a finished one is a run whose
  # numbers are final.
  def summary(%SyncRun{status: "running"} = run), do: "#{pages(run)} pages so far"
  def summary(%SyncRun{status: "failed"} = run), do: "failed after #{pages(run)} pages"
  def summary(%SyncRun{status: "cancelled"} = run), do: "stopped at #{pages(run)} pages"

  def summary(run),
    do: "#{pages(run)} listed · #{count(run, "changed")} changed"

  @impl true
  def detail(%SyncRun{error: error}) when is_binary(error) and error != "", do: error

  def detail(run), do: "run ##{run.id} of #{run.scope || "the whole site"}, mode #{run.mode}"

  @impl true
  def log(run), do: {"log", ~p"/admin/sync-log?run=#{run.id}"}

  defp pages(run), do: count(run, "pages")

  defp count(run, key), do: run.stats |> Map.get(key, 0) |> to_string()

  defp tone("running"), do: :running
  defp tone("succeeded"), do: :ok
  defp tone("partial"), do: :warn
  defp tone("cancelled"), do: :idle
  defp tone("failed"), do: :error
  defp tone(_other), do: :idle
end
