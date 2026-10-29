defmodule ConfluencePhxMirror.Sync do
  @moduledoc """
  The ingestion pipeline.

  A sync has three jobs:

    1. **upsert** spaces and pages (identity, metadata, storage format),
    2. **render** each page's `export_view`, rewrite links and extract labels,
       links and search text,
    3. **mirror attachments** into the blob store and comments into Postgres.

  Every run is recorded as a `SyncRun` and audited. A failing page does not
  abort the run; it is collected as a per-page error and the run ends
  `partial`, so one broken macro can never take the whole mirror down.
  """

  import Ecto.Query
  require Logger

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Confluence.Traffic
  alias ConfluencePhxMirror.Metrics
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page, Space}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.PageUpdates
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirror.SiteSettings
  alias Oban.Job

  alias ConfluencePhxMirror.Sync.{
    Cancelled,
    DynamicContent,
    Emoticons,
    Gate,
    Log,
    PageProperties,
    Renderer,
    Runs,
    SpaceScope,
    SyncRun
  }

  # Named because `request_people/1` queues it; a sibling module's short name is
  # not an implicit alias inside this one.
  alias ConfluencePhxMirror.Sync.PeopleWorker

  @type mode :: :snapshot | :incremental | :space | :page | :people
  @type report :: {:ok, SyncRun.t()}

  # ---------------------------------------------------------------------------
  # Public entry points
  # ---------------------------------------------------------------------------

  @doc """
  Runs a sync and records it.

  Options:

    * `:confluence_id` – required for `:page`
    * `:space_key` – required for `:space`
    * `:since` – for `:incremental`, defaults to one sync interval ago
    * `:actor` – audit actor, defaults to the system
    * `:trigger` – why the run happened, in words: "the hourly schedule",
      "the admin dashboard, by jane@acme.com"
    * `:source` – upstream source module, defaults to the configured one
    * `:job_id` – the Oban job that asked for this run, so the admin jobs page
      can show a job's progress and its log; absent for `mix confluence.sync`
    * `:gate` – what keeps two runs apart, defaults to `Sync.Gate`; a caller that
      owns the mirror outright (a test with its own database) may pass its own
  """
  @spec run(mode(), keyword()) :: report() | {:error, :already_running} | {:error, :paused}
  def run(mode, opts \\ []) do
    gate = Keyword.get(opts, :gate, Gate)

    if Settings.sync_paused?() do
      # Refused before a row is written and before the source is asked: a paused
      # mirror makes no calls, and a run that did not happen is not a failure to
      # report. The workers turn this into a wait (see `paused_wait/0`).
      {:error, :paused}
    else
      # A `running` row whose owner is gone is not a run in flight. Clear those
      # before taking the lock, because while we hold it we cannot tell ours from
      # anyone else's.
      abandon_abandoned_runs()

      case gate.exclusive(fn gate_owner ->
             run_locked(mode, Keyword.put(opts, :gate_owner, gate_owner))
           end) do
        {:ok, result} ->
          # The run just moved the mirror: publish the totals now, rather than
          # leaving it to the poller's next tick. A run that changed nothing
          # publishes the same numbers, which costs one point on a chart.
          Metrics.publish()
          result

        {:error, :already_running} = busy ->
          busy
      end
    end
  end

  @doc """
  Queues a job that will read the site.

  While the mirror is paused nothing it queues can run, so a request that arrives
  meanwhile says the same thing as the job already waiting: "look at this again
  when the pause ends". It joins that job instead of adding one behind it, which
  keeps the queue one row per page or space however long the pause lasts.

  Coalescing loses nothing precisely because nothing is read: the job that
  survives reads the page, space or group as it stands when it finally runs,
  whatever the requests it absorbed had to say. An unserialised window of this
  kind would be wrong in the ordinary case — an event arriving while a run holds
  the page may be about a change that run will not see — so a mirror that is not
  paused keeps each worker's own uniqueness period.

  Returns what `Oban.insert/1` returns. For a coalesced request the job is the
  one already in the queue, with `conflict?: true`.
  """
  @spec enqueue(module(), map(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def enqueue(worker, args, opts \\ []) do
    worker.new(args, coalescing(opts))
    |> Oban.insert()
  end

  defp coalescing(opts) do
    if Settings.sync_paused?() do
      Keyword.update(opts, :unique, [period: :infinity], &Keyword.put(&1, :period, :infinity))
    else
      opts
    end
  end

  @doc """
  Queues a read of who the site says is in which group, and of each account's own
  status — no page, no body.

  What an administrator asks when somebody left a group, joined one, was made an
  administrator, or was switched off upstream, and the hours until the next
  scheduled pull are too long. `trigger` says who asked, the way every run's log
  names its cause.
  """
  @spec request_people(String.t()) :: {:ok, Job.t()} | {:error, term()}
  def request_people(trigger) when is_binary(trigger) do
    enqueue(PeopleWorker, %{"trigger" => trigger})
  end

  @doc """
  What a job should do when the mirror is paused: come back later.

  A snooze keeps the job (and its place in the queue) instead of failing it, and
  does not spend an attempt — a pause of an hour must not turn into a `discarded`
  job that a resume then never repairs.
  """
  @spec paused_wait() :: {:snooze, pos_integer()}
  def paused_wait, do: {:snooze, 300}

  # One request per run, before any content: what the site calls itself and how
  # it spells its language. A source with no site, or a site that will not say,
  # changes nothing — a title is not worth failing a run over.
  defp read_site_settings(source, run) do
    if function_exported?(source, :site_settings, 1) do
      case source.site_settings([]) do
        {:ok, settings} ->
          if SiteSettings.put(settings) == :changed do
            Log.add(:info, "the site's own configuration changed: #{describe(settings)}",
              sync_run_id: run.id
            )
          end

          :ok

        {:error, :not_supported} ->
          :ok

        {:error, reason} ->
          Log.add(:warn, "could not read the site's own configuration: #{inspect(reason)}",
            sync_run_id: run.id
          )

          :ok
      end
    end
  end

  defp describe(settings) do
    [
      settings[:title] && "title #{inspect(settings[:title])}",
      settings[:locale] && "language #{settings[:locale]}",
      settings[:timezone] && "time zone #{settings[:timezone]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp run_locked(mode, opts) do
    source = Keyword.get(opts, :source, Source.source())
    actor = Keyword.get(opts, :actor, {:system, "sync"})
    trigger = Keyword.get(opts, :trigger)
    # One mirror holds one site's content; never let a sync write across sites.
    Sites.verify!()
    run = start_run(source, mode, actor, trigger, opts)
    # The loops ask the row whether someone asked them to stop.
    opts = Keyword.put(opts, :run_id, run.id)

    Logger.info("sync started",
      sync_run_id: run.id,
      mode: mode_to_string(mode),
      source: source_label(source),
      trigger: trigger
    )

    Log.current_run(run.id)

    Log.add(:info, "started a #{mode} sync of #{source_label(source)}",
      sync_run_id: run.id,
      trigger: trigger
    )

    read_site_settings(source, run)

    try do
      {stats, errors} = run_work(mode, source, opts, run)
      finish_run(run, stats, errors, actor, trigger)
    rescue
      Cancelled ->
        finish_cancelled(run, actor, trigger)

      error ->
        fail_run(run, Exception.message(error), trigger)

        Logger.error("sync failed",
          sync_run_id: run.id,
          mode: mode_to_string(mode),
          source: source_label(source),
          reason: Exception.message(error)
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        fail_run(run, Exception.format(kind, reason, __STACKTRACE__), trigger)

        Logger.error("sync failed",
          sync_run_id: run.id,
          mode: mode_to_string(mode),
          source: source_label(source),
          reason: Exception.format(kind, reason, __STACKTRACE__)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp source_label(source) do
    if function_exported?(source, :name, 0), do: source.name(), else: inspect(source)
  end

  # The work runs in a child of the process that owns the run row, not in it:
  # the row, the audit entry and the gate have to outlive the work being
  # stopped. A cancel exits this child (see `Runs.stop/1`), which is immediate
  # and can land anywhere. What makes that safe is the write boundary:
  #
  #   * a page's version change stores the new body and clears
  #     `details_synced_at` in one transaction, so an interrupted detail pass is
  #     simply a page the backlog reads again — never a page claiming details
  #     that were not written;
  #   * the details of a page (text, links, comments, that same mark) are one
  #     transaction too, and they check for a stop before writing, so they land
  #     whole or not at all;
  #   * blob files are named by page, attachment and filename, so a file written
  #     by work that rolled back is reused, not duplicated.
  defp run_work(mode, source, opts, run) do
    parent = self()
    tag = make_ref()

    {pid, ref} =
      spawn_monitor(fn ->
        # `$callers` is what the Ecto sandbox (and anything else that asks
        # "whose work is this?") reads; a spawned process has to inherit it by
        # hand, which is also what makes the child's database work legal in a
        # test that owns the sandbox.
        Process.put(:"$callers", [parent | Process.get(:"$callers", [])])
        Log.current_run(run.id)
        Logger.metadata(sync_run_id: run.id)
        Runs.register(run.id)

        result =
          try do
            check_cancelled!(opts)
            {stats, errors} = do_run(mode, source, opts)
            {:ok, reconcile_accounts(mode, source, stats, errors, opts)}
          rescue
            error -> {:error, error, __STACKTRACE__}
          catch
            kind, reason -> {:caught, kind, reason, __STACKTRACE__}
          end

        send(parent, {tag, result})
      end)

    receive do
      {^tag, {:ok, report}} ->
        Process.demonitor(ref, [:flush])
        report

      {^tag, {:error, error, stacktrace}} ->
        reraise error, stacktrace

      {^tag, {:caught, kind, reason, stacktrace}} ->
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        # No result message: the child was stopped on request, or died in a way
        # it could not report. A stop is a cancellation, not a failure.
        case reason do
          :shutdown ->
            raise Cancelled

          :killed ->
            raise Cancelled

          :normal ->
            raise Cancelled

          # The pages run in tasks linked to the child, so a raise inside a page
          # leaves the child with that exception as its exit reason — a stop
          # that landed there, or the page's own failure, which is re-raised as
          # itself rather than as "the process exited".
          {%Cancelled{}, _stacktrace} ->
            raise Cancelled

          {exception, stacktrace} when is_exception(exception) ->
            reraise(exception, stacktrace)

          other ->
            raise "the sync process exited: #{inspect(other)}"
        end
    end
  end

  # ---------------------------------------------------------------------------
  # One run at a time, and stopping one
  # ---------------------------------------------------------------------------

  @abandoned "the process running this sync stopped before it finished"

  # The modes that read the whole site, as opposed to one space or one page.
  @whole_site_modes ~w(snapshot incremental)

  @doc """
  Stops a running sync.

  The request is recorded on the row first, because that is the only signal a
  run on another node or in `mix confluence.sync` can see. When the run is on
  this node the process doing the work is exited as well, so the stop is
  immediate rather than "after the next page": the page in flight is one
  transaction and rolls back, and the run ends `cancelled` with the pages it
  already wrote.

  Returns `{:error, :not_running}` when there is nothing to stop — a run that
  already finished, or one that never started.
  """
  @spec cancel(Ecto.UUID.t() | integer(), Audit.actor()) ::
          {:ok, SyncRun.t()} | {:error, :not_running}
  def cancel(run_id, actor) do
    run_id = cancel_id(run_id)

    # The exit first, the row second: the work stops now, and the transaction it
    # was in is already rolling back by the time the row is written. The row is
    # still the record — and still the only signal a run elsewhere can see.
    stopped = Runs.stop(run_id)

    case Repo.get(SyncRun, run_id) do
      %SyncRun{status: "running"} = run ->
        {:ok, run} =
          run
          |> SyncRun.changeset(%{cancel_requested_at: now()})
          |> Repo.update()

        Log.add(:warn, cancel_message(stopped),
          sync_run_id: run.id,
          by: actor_name(actor)
        )

        {:ok, run}

      %SyncRun{} = run when stopped == :stopped ->
        # The process was ours and is gone; its parent is recording the outcome.
        {:ok, run}

      _finished_or_missing ->
        {:error, :not_running}
    end
  end

  defp cancel_message(:stopped), do: "cancellation requested: stopping the run now"

  defp cancel_message(:elsewhere),
    do:
      "cancellation requested, stopping at the next page (the run is on another node or process)"

  # The dashboard sends the id it rendered, which arrives as a string.
  defp cancel_id(id) when is_integer(id), do: id

  defp cancel_id(id) do
    case Integer.parse(to_string(id)) do
      {parsed, ""} -> parsed
      _ -> id
    end
  end

  @doc """
  Whether a run that covers the whole site is in flight — a snapshot or an
  incremental pull, as opposed to one space or one page.

  A job that exists to read a single space has nothing to do while the whole site
  is being read: the run is reading that space too. Asking is what lets such a
  job stand down instead of waiting for a turn that will not come.
  """
  @spec whole_site_running?() :: boolean()
  def whole_site_running? do
    Repo.exists?(from r in SyncRun, where: r.status == "running" and r.mode in ^@whole_site_modes)
  end

  @doc """
  What a job that reads one space or one page should do when a sync is already in
  flight: wait, or stand down.

  Waiting is right against another single-space run, which will be done shortly.
  Standing down is right against a whole-site run, which is reading that space
  anyway — and which, on a slow site, can be in flight for hours. A hundred and
  forty jobs snoozing through such a run is what the queue looked like after one
  stuck snapshot.
  """
  @spec wait_or_stand_down() :: {:snooze, pos_integer()} | {:cancel, atom()}
  def wait_or_stand_down do
    if whole_site_running?(), do: {:cancel, :superseded_by_a_whole_site_run}, else: {:snooze, 30}
  end

  @doc """
  Marks `running` rows as failed when no one holds the sync lock.

  A run outlives its row only while its node holds the advisory lock (see
  `Sync.Gate`), so a free lock plus a running row means the node that owned it
  died — a deploy, an OOM kill, a Machine going away. Saying so beats leaving a
  run that looks busy forever, and beats a timeout that would have to guess.

  The job of such a run is cancelled with it, and so is any job left `executing`
  while the lock is free — but only a job that runs under the lock, because that
  is the whole of the evidence: holding the lock is how a job proves it is
  alive, and a synchronised worker that is not holding it has nothing behind its
  row. Oban's own rescuer cannot help promptly — it may not, since a long
  listing is not a dead node (see `config/config.exs`) — and an `executing` job
  keeps its uniqueness, which turns the next scheduled pull away for as long as
  it stays stuck.

  A sweep and a trash pass are on the same queue and take no lock, because they
  are not a sync: they copy nothing and ask one question. Reading their silence
  as death cancelled every sweep a minute after it started. Their liveness is
  Oban's business (six hours of silence is past any sweep) or an administrator's
  cancellation.

  A verify pass does take the lock — it asks the whole site what it lists, which
  is longer than a sweep and, unlike a sweep, must not run beside a sync — so it
  is judged by it like a run. That is what killed the job production lost six
  hours to: a pass whose node died stayed `executing`, and its uniqueness turned
  every later schedule away until Oban's lifeline noticed.

  Returns how many runs it closed.
  """
  @spec abandon_abandoned_runs() :: non_neg_integer()
  def abandon_abandoned_runs do
    if Gate.held?() do
      0
    else
      runs = from(r in SyncRun, where: r.status == "running") |> Repo.all()
      Enum.each(runs, &abandon_run/1)
      release_orphaned_jobs()
      length(runs)
    end
  end

  # A job that has only just started has not taken the lock yet, so give it a
  # moment before reading silence as death.
  @gate_grace_seconds 60

  # The workers that take the lock themselves, and therefore the only jobs the
  # sweep may judge. Adding a worker to this list says "a free lock means my
  # process is gone"; leaving one out says "I run beside the lock, and may".
  @synchronised_workers [
    ConfluencePhxMirror.Sync.PageWorker,
    ConfluencePhxMirror.Sync.PeopleWorker,
    ConfluencePhxMirror.Sync.ReconcileWorker,
    ConfluencePhxMirror.Sync.SnapshotWorker,
    ConfluencePhxMirror.Sync.SpaceWorker
  ]

  defp release_orphaned_jobs do
    cutoff = DateTime.add(DateTime.utc_now(), -@gate_grace_seconds, :second)
    # Oban records a worker as its module name without the `Elixir.` prefix.
    workers = Enum.map(@synchronised_workers, &inspect/1)

    from(j in Job,
      where: j.queue == "sync" and j.state == "executing" and j.attempted_at < ^cutoff,
      where: j.worker in ^workers
    )
    |> Repo.all()
    |> Enum.each(fn job ->
      :ok = Oban.cancel_job(job)

      Log.add(
        :warn,
        "sync job #{job.id} was left running by a process that is gone; cancelled it"
      )
    end)
  end

  defp abandon_run(run) do
    reason = abandoned_reason(run)

    {:ok, run} =
      run
      |> SyncRun.changeset(%{status: "failed", finished_at: now(), error: reason})
      |> Repo.update()

    Log.add(:warn, "sync #{run.id} was abandoned: #{reason}", sync_run_id: run.id)
    Audit.log(Audit.system_actor(), SyncRun.audit_event_abandoned(run))
  end

  # A run that stopped cannot say why, so the row says what is known: the
  # process is gone, and how long the row had been silent before anyone noticed
  # — an hour of silence and a deploy are different incidents, and until now
  # both read as the same sentence.
  defp abandoned_reason(%SyncRun{updated_at: nil}), do: @abandoned

  defp abandoned_reason(run) do
    quiet_seconds = max(DateTime.diff(now(), run.updated_at, :second), 0)
    "#{@abandoned} (#{quiet_seconds}s without progress)"
  end

  defp finish_cancelled(run, actor, trigger) do
    # Whatever the progress flushes left on the row is the honest total: the
    # pages copied before the stop are in the mirror, so the run reports them.
    stats = Repo.get(SyncRun, run.id).stats || %{}

    {:ok, run} =
      run
      |> SyncRun.changeset(%{
        status: "cancelled",
        finished_at: now(),
        stats: stats,
        error: "stopped on request; the #{stats["pages"] || 0} pages listed before that stay"
      })
      |> Repo.update()

    Log.add(:warn, "sync cancelled: #{stats["pages"] || 0} pages were listed first",
      sync_run_id: run.id
    )

    log_traffic_summary()
    Log.current_run(nil)

    Audit.log(actor, SyncRun.audit_event_cancelled(run, by: actor_name(actor), trigger: trigger))

    {:ok, run}
  end

  defp actor_name({:user, %{email: email}}), do: email
  defp actor_name({:system, name}), do: name
  defp actor_name(other), do: inspect(other)

  # Checked between pages, never inside one: a page is written in a transaction
  # of its own, so stopping between two of them leaves nothing half-done.
  # How many already-current pages a run names in its log before it settles for
  # the total. Naming them is what turns "1 listed, 1 unchanged" into an answer.
  @listed_by_name 20

  @cancel_check_every 10
  defp check_cancelled!(opts) do
    case opts[:run_id] do
      nil -> :ok
      run_id -> if cancel_requested?(run_id), do: raise(Cancelled), else: :ok
    end
  end

  defp cancel_requested?(run_id) do
    Repo.exists?(from(r in SyncRun, where: r.id == ^run_id and not is_nil(r.cancel_requested_at)))
  end

  # The dashboard shows a run while it runs, so the counters have to move while
  # the run moves: the row is written as the pages are counted, not only at the
  # end. The phase is what the dashboard's live strip names.
  defp record_progress(opts, counts) do
    record_stats(opts, Map.put(page_counts(counts), "phase", "pages"))
  end

  # Which step the run is on now, for the same strip.
  defp record_phase(opts, phase), do: record_stats(opts, %{"phase" => phase})

  # Stats are merged, not replaced: the trigger written when the run started has
  # to survive every flush, or the strip loses the reason the run happened.
  defp record_stats(opts, changes) do
    with run_id when not is_nil(run_id) <- opts[:run_id],
         %SyncRun{} = run <- Repo.get(SyncRun, run_id) do
      Repo.update_all(from(r in SyncRun, where: r.id == ^run_id),
        set: [stats: Map.merge(run.stats || %{}, changes)]
      )
    else
      _no_run -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # The queue
  # ---------------------------------------------------------------------------

  # Waiting for a free slot, for its schedule, or for its next attempt — the
  # states in which a job has not started. `executing` is deliberately absent:
  # once a job runs it is a run, and stopping it is `cancel/2`.
  @queued_states ~w(available scheduled retryable)

  @doc """
  The sync jobs waiting their turn, next first.

  The queue is a place an operator acts on — a webhook storm, a wrong press of
  "sync one space" — so the dashboard lists what waits there beside the runs
  that already happened, rather than only inside Oban's own tables.
  """
  @spec queued(pos_integer()) :: [Job.t()]
  def queued(limit \\ 10) do
    from(j in Job,
      where: j.queue == "sync" and j.state in ^@queued_states,
      order_by: [asc: j.scheduled_at, asc: j.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Drops a queued sync before anything picks it up.

  The state filter is part of the update, so a job that started between the
  page rendering and the click is left alone — the caller gets
  `{:error, :not_queued}` and stops offering the button. What was cancelled
  keeps its row, marked `cancelled`, and is audited, so the queue remembers
  that someone dropped the work.
  """
  @spec cancel_queued(integer(), Audit.actor()) :: {:ok, Job.t()} | {:error, :not_queued}
  def cancel_queued(job_id, actor) when is_integer(job_id) do
    with %Job{} = job <- Repo.get(Job, job_id),
         {:ok, 1} <-
           Oban.cancel_all_jobs(
             from(j in Job, where: j.id == ^job_id and j.state in ^@queued_states)
           ) do
      Log.add(:warn, "a queued sync was cancelled before it started", by: actor_name(actor))
      Audit.log(actor, audit_event_dequeued(job, actor))

      {:ok, Repo.get(Job, job_id)}
    else
      _gone_or_started -> {:error, :not_queued}
    end
  end

  defp audit_event_dequeued(job, actor) do
    Audit.Entry.new("sync.dequeued", "sync_job", job.id, %{
      worker: job.worker,
      args: job.args,
      by: actor_name(actor)
    })
  end

  # ---------------------------------------------------------------------------
  # Account status
  # ---------------------------------------------------------------------------

  # A page sync is one page; asking the site about every known account belongs
  # to the runs that see the site as a whole.
  defp reconcile_accounts(:page, _source, stats, errors, _opts), do: {stats, errors}

  defp reconcile_accounts(_mode, source, stats, errors, opts) do
    record_phase(opts, "accounts")
    {checked, account_errors} = sync_account_statuses(source, opts)
    {Map.put(stats, "accounts", checked), errors ++ account_errors}
  end

  # Who might be switched off on the site while still holding a mirror account:
  # every Atlassian account id the mirror knows. A snapshot has to ask about a
  # lot of people, so the sweep is capped; the accounts that signed in here are
  # checked first, because those are the rows a flag actually changes.
  @max_account_checks 500

  defp sync_account_statuses(source, opts) do
    if function_exported?(source, :user_status, 2) do
      account_ids(opts)
      |> Enum.reduce({0, []}, fn id, acc -> check_account(source, id, acc, opts) end)
    else
      {0, []}
    end
  end

  defp account_ids(opts) do
    ids =
      (Accounts.account_ids() ++ Mirror.member_account_ids() ++ Mirror.account_ids())
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case Keyword.get(opts, :people_limit, @max_account_checks) do
      :all -> ids
      limit -> Enum.take(ids, limit)
    end
  end

  defp check_account(source, account_id, {checked, errors}, opts) do
    case source.user_status(account_id, opts) do
      {:ok, status} ->
        Accounts.reconcile_site_status(
          account_id,
          Map.get(status, :email),
          site_state(Map.get(status, :account_status)),
          display_name: Map.get(status, :display_name)
        )

        {checked + 1, errors}

      # The site has no such account any more. That is not a failure and not a
      # switch-off: it is the one state a deployment may not relax.
      {:error, :not_found} ->
        Accounts.reconcile_site_status(account_id, nil, :deleted)
        {checked, errors}

      {:error, :not_supported} ->
        {checked, errors}

      {:error, reason} ->
        {checked, [error("account", account_id, reason) | errors]}
    end
  end

  # Atlassian reports `active`, `inactive` or `closed`, and nobody but `active`
  # can use the site. `closed` cannot be undone there, which is the mirror's
  # notion of deleted. Anything we do not recognise counts as switched off,
  # never as active: a site that says nothing is not evidence of anything.
  defp site_state("active"), do: :active
  defp site_state("inactive"), do: :disabled
  defp site_state("closed"), do: :deleted
  defp site_state(_unknown), do: :disabled

  # ---------------------------------------------------------------------------
  # Modes
  # ---------------------------------------------------------------------------

  # One page, read from the site: the parts a webhook's single page needs, in
  # the order that leaves the mirror readable at every step.
  defp sync_page(source, previous, confluence_id, opts) do
    with {:ok, dto} <- source.page(confluence_id, opts),
         {:ok, space, icon_errors} <- ensure_space(source, dto.space_key, opts),
         {:ok, entry} <- upsert_page_record(space, dto, previous, force: true) do
      resolve_trees([space])
      index = Mirror.page_index()
      record_phase(opts, "people")
      {members, group_errors, _refreshed} = sync_groups(source, opts)
      record_phase(opts, "details")
      {stats, errors} = sync_details(source, [entry], index, opts)
      {_spaces, permission_errors} = sync_space_permissions(source, [space])
      {group_rows, referenced_errors} = refresh_groups(source, opts)
      refresh_dynamic_pages()

      {Map.merge(stats, %{
         "spaces" => 1,
         "pages" => 1,
         "changed" => if(entry.change == :updated, do: 1, else: 0),
         "unchanged" => if(entry.change == :unchanged, do: 1, else: 0),
         "group_members" => members + group_rows
       }), errors ++ icon_errors ++ permission_errors ++ group_errors ++ referenced_errors}
    else
      {:error, reason} -> raise_source_error(:page, confluence_id, reason)
    end
  end

  # A run that read nothing is still a run that has to say so: the log line is
  # the answer to "why did the webhook do nothing?".
  defp left_live_doc_alone(previous, confluence_id) do
    age = DateTime.diff(now(), previous.synced_at)

    Log.add(
      :info,
      "left live doc #{previous.title} alone: its copy is #{age}s old, and live docs " <>
        "are read at most every #{Settings.live_doc_refresh_seconds()}s",
      confluence_id: confluence_id
    )

    {%{changed: 0, unchanged: 1}
     |> page_counts()
     |> Map.merge(%{"spaces" => 0, "group_members" => 0}), []}
  end

  defp do_run(:snapshot, source, opts) do
    case source.spaces(opts) do
      {:ok, space_dtos} ->
        # Who may read what comes first: membership decides access, so it is
        # settled from the identities the mirror already has before content
        # moves. Anyone this run's pages introduce is added after the pages.
        record_phase(opts, "people")
        {people, people_errors, refreshed} = sync_groups(source, opts)
        record_phase(opts, "spaces")

        {space_dtos, skipped} = importable_spaces(space_dtos)
        {space_dtos, outside} = whitelisted_spaces(space_dtos)
        skipped = skipped + length(outside)

        # Asked before the filters, so "not listed" means the site did not name
        # it rather than "somebody narrowed CM_SPACES".
        {unlisted, unlisted_errors} = unlisted_spaces(space_dtos)

        {spaces, icon_errors} = upsert_spaces(source, space_dtos)
        {spaces_trashed, pages_trashed} = trash_outside_whitelist(outside)
        {spaces, permission_errors} = sync_space_permissions(source, spaces)

        {entries, counts, errors, absent} = sync_pages_of(spaces, source, opts)
        resolve_trees(spaces)
        index = Mirror.page_index()

        record_phase(opts, "people")
        {new_people, newcomer_errors, _} = sync_groups(source, opts, newcomers(refreshed))
        record_phase(opts, "details")
        {stats, detail_errors} = sync_details(source, entries, index, opts)
        relink_attachment_links()

        # Restrictions and permissions are in by now, so the groups the content
        # depends on can finally be asked about.
        record_phase(opts, "groups")
        {group_rows, group_errors} = refresh_groups(source, opts)

        stats =
          Map.merge(stats, %{
            "spaces" => length(spaces),
            "skipped_spaces" => skipped,
            "absent" => absent,
            "spaces_unlisted" => unlisted,
            "spaces_trashed" => spaces_trashed,
            "pages_trashed" => pages_trashed,
            "group_members" => people + new_people + group_rows
          })
          |> Map.merge(page_counts(counts))

        {stats,
         errors ++
           unlisted_errors ++
           icon_errors ++
           permission_errors ++
           people_errors ++ newcomer_errors ++ detail_errors ++ group_errors}

      {:error, reason} ->
        raise_source_error(:spaces, nil, reason)
    end
  end

  defp do_run(:space, source, opts) do
    space_key = Keyword.fetch!(opts, :space_key)

    with {:ok, space, icon_errors} <- ensure_space(source, space_key, opts) do
      record_phase(opts, "people")
      {people, people_errors, refreshed} = sync_groups(source, opts)
      record_phase(opts, "spaces")
      {_spaces, permission_errors} = sync_space_permissions(source, [space])
      {entries, counts, errors, absent} = sync_pages_of([space], source, opts)
      resolve_trees([space])
      index = Mirror.page_index()

      record_phase(opts, "people")
      {new_people, newcomer_errors, _} = sync_groups(source, opts, newcomers(refreshed))
      record_phase(opts, "details")
      {stats, detail_errors} = sync_details(source, entries, index, opts)
      record_phase(opts, "groups")
      {group_rows, group_errors} = refresh_groups(source, opts)
      members = people + new_people + group_rows

      stats =
        Map.merge(stats, %{"spaces" => 1, "absent" => absent, "group_members" => members})
        |> Map.merge(page_counts(counts))

      {stats,
       errors ++
         icon_errors ++
         permission_errors ++
         people_errors ++ newcomer_errors ++ detail_errors ++ group_errors}
    end
  end

  # The people half of a run, on request: every identity the mirror knows is
  # asked which groups it is in, and every group the content names is read for
  # its members. No page is listed and no page body is read, so it is cheap
  # enough for "somebody was added to a group, say so now".
  defp do_run(:people, source, opts) do
    # The operator asked exactly this question, so the per-run cap that keeps a
    # snapshot bounded does not apply.
    opts = Keyword.put(opts, :people_limit, :all)

    record_phase(opts, "people")
    {members, people_errors, _refreshed} = sync_groups(source, opts)

    record_phase(opts, "groups")
    {group_rows, group_errors} = refresh_groups(source, opts)

    stats =
      %{changed: 0, unchanged: 0}
      |> page_counts()
      |> Map.put("group_members", members + group_rows)

    {stats, people_errors ++ group_errors}
  end

  defp do_run(:page, source, opts) do
    confluence_id = Keyword.fetch!(opts, :confluence_id)
    previous = Page |> Repo.get_by(confluence_id: confluence_id) |> light()

    # The webhook is right that a live doc changed; it says so every few
    # seconds. Reading it again would spend a body fetch, a render and a detail
    # pass on a copy nobody in the room needs, so a young live doc is answered
    # from what the mirror holds. An administrator's resync passes `force: true`
    # because "now" is exactly what pressing it means.
    if live_doc_fresh?(previous) and not Keyword.get(opts, :force, false) do
      left_live_doc_alone(previous, confluence_id)
    else
      sync_page(source, previous, confluence_id, opts)
    end
  end

  defp do_run(:incremental, source, opts) do
    since = Keyword.get(opts, :since, default_since())

    case source.changed_since(since, opts) do
      {:ok, dtos} ->
        {extra, touched, touched_errors} = touched_pages(source, dtos, since, opts)

        # A page in a personal space is not imported through the side door.
        {dtos, skipped_personal} = drop_personal_pages(source, dtos ++ extra, opts)

        record_phase(opts, "people")
        {people, people_errors, refreshed} = sync_groups(source, opts)
        record_phase(opts, "spaces")
        {spaces, icon_errors} = ensure_spaces_for(source, dtos, opts)

        # A space the site names and this mirror has never listed is read here,
        # whatever mode the run is: `changed_since` only reports pages that
        # moved inside its window, so such a space would otherwise wait for a
        # snapshot nobody knew to run.
        {discovered, discovered_counts, discovered_errors, absent, skipped_spaces} =
          discover_spaces(source, opts)

        spaces = Enum.uniq_by(spaces ++ discovered, & &1.id)
        {spaces, permission_errors} = sync_space_permissions(source, spaces)

        {entries, changed_counts, errors} =
          upsert_entries(dtos, spaces, Keyword.put(opts, :force, touched))

        counts = add_counts(changed_counts, discovered_counts)

        resolve_trees(spaces)
        log_listing(dtos, entries)
        index = Mirror.page_index()

        record_phase(opts, "people")
        {new_people, newcomer_errors, _} = sync_groups(source, opts, newcomers(refreshed))
        record_phase(opts, "details")
        {stats, detail_errors} = sync_details(source, entries, index, opts)
        record_phase(opts, "backlog")
        {caught_up, catch_up_errors} = catch_up_details(source, opts)
        record_phase(opts, "groups")
        {group_rows, group_errors} = refresh_groups(source, opts)

        stats =
          stats
          |> Map.merge(caught_up)
          |> Map.merge(%{
            "spaces" => length(spaces),
            "spaces_discovered" => length(discovered),
            "absent" => absent,
            "skipped_spaces" => skipped_spaces,
            "skipped_personal" => skipped_personal,
            "details_relisted" => length(extra),
            "group_members" => people + new_people + group_rows
          })
          |> Map.merge(page_counts(counts))

        {stats,
         errors ++
           touched_errors ++
           icon_errors ++
           discovered_errors ++
           permission_errors ++
           people_errors ++
           newcomer_errors ++
           detail_errors ++
           catch_up_errors ++
           group_errors}

      {:error, :not_supported} ->
        do_run(:snapshot, source, opts)

      {:error, reason} ->
        raise_source_error(:changed_since, since, reason)
    end
  end

  # Comments and attachments have versions of their own and never bump their
  # page's, so the page window cannot see them: a reply arrives, a screenshot is
  # pasted in, and the page stays at version 1 while an incremental run reports
  # nothing to do. The pages whose children moved are read and handed to the
  # detail pass as forced work.
  defp touched_pages(source, dtos, since, opts) do
    if function_exported?(source, :touched_since, 2) do
      case source.touched_since(since, opts) do
        {:ok, touched} ->
          known = MapSet.new(dtos, & &1.id)

          {extra, errors} =
            fetch_pages(source, Enum.reject(touched.pages, &MapSet.member?(known, &1)), opts)

          if touched.space_attachments > 0 do
            Log.add(
              :info,
              "#{touched.space_attachments} file(s) changed that belong to a space, not a page",
              kind: :sync
            )
          end

          {extra, MapSet.new(touched.pages), errors}

        {:error, reason} ->
          # The run still does what it can: the pages are mirrored either way,
          # and the failure is reported as an error on the run rather than
          # swallowed into a clean-looking sync.
          Log.add(
            :warn,
            "could not ask what comments and attachments changed: #{inspect(reason)}"
          )

          {[], MapSet.new(), [error("comments", since, reason)]}
      end
    else
      {[], MapSet.new(), []}
    end
  end

  # Pages a changed comment or file pointed at: read so the detail pass can run
  # against them. A page deleted between the two queries is not an error here —
  # the page listing owns deletion.
  defp fetch_pages(source, ids, opts) do
    {dtos, errors} =
      Enum.map_reduce(ids, [], fn id, errors ->
        case source.page(id, opts) do
          {:ok, dto} -> {dto, errors}
          {:error, :not_found} -> {nil, errors}
          {:error, reason} -> {nil, [error("page", id, reason) | errors]}
        end
      end)

    {Enum.reject(dtos, &is_nil/1), errors}
  end

  # A run that says "1 listed, 1 unchanged" and stops leaves the reader asking
  # which page and why nothing happened. While the listing is small the pages are
  # named, with the version the site reported; a snapshot says only the totals.
  defp log_listing(dtos, entries) do
    visited = MapSet.new(entries, & &1.dto.id)
    current = Enum.reject(dtos, &MapSet.member?(visited, &1.id))

    case length(current) do
      count when count in 1..@listed_by_name ->
        Enum.each(current, fn dto ->
          Log.add(:info, "already current: #{dto.title}",
            page: dto.id,
            space: dto.space_key,
            version: dto.version.number,
            modified: DateTime.to_iso8601(dto.updated_at)
          )
        end)

      count when count > @listed_by_name ->
        Log.add(:debug, "#{count} pages were already current; not named one by one",
          unchanged: count
        )

      _none ->
        :ok
    end
  end

  # A page whose details were never read — a mirror upgraded to this rule, or a
  # run that died between the page and its comments — has nothing pointing back
  # at it: its own version will not move again. Rather than walking every page
  # in the mirror, the index is asked which pages have comments or files at all,
  # and the ones whose details are missing are read; a source that cannot answer
  # is walked in id order instead. Either way the work per run is bounded and
  # what happened is reported.
  defp catch_up_details(source, opts) do
    if Mirror.pages_awaiting_details(1) == [] do
      # The common case: one query and no requests to Confluence.
      {%{}, []}
    else
      {ids, errors} = backlog_of(source, detail_backlog(), opts)
      detail_backlog_pages(source, ids, errors, opts)
    end
  end

  defp backlog_of(source, limit, opts) do
    if function_exported?(source, :touched_since, 2) do
      case source.touched_since(nil, opts) do
        {:ok, touched} ->
          case Mirror.pages_awaiting_details_among(touched.pages, limit) do
            [] -> {Mirror.pages_awaiting_details(limit), []}
            ids -> {ids, []}
          end

        {:error, reason} ->
          # Reported, not swallowed: the id walk still runs, and the operator
          # sees that the cheap question was not answered.
          Log.add(:warn, "could not ask which pages have comments or files: #{inspect(reason)}")
          {Mirror.pages_awaiting_details(limit), [error("comments", :backlog, reason)]}
      end
    else
      {Mirror.pages_awaiting_details(limit), []}
    end
  end

  defp detail_backlog_pages(_source, [], errors, _opts), do: {%{}, errors}

  defp detail_backlog_pages(source, ids, errors, opts) do
    {dtos, fetch_errors} = fetch_pages(source, ids, opts)
    {spaces, icon_errors} = ensure_spaces_for(source, dtos, opts)

    {entries, _counts, upsert_errors} =
      upsert_entries(dtos, spaces, Keyword.put(opts, :force, MapSet.new(ids)))

    resolve_trees(spaces)
    {stats, detail_errors} = sync_details(source, entries, Mirror.page_index(), opts)

    Log.add(:info, "caught up on #{length(entries)} page(s) whose details had never been read",
      pages: length(entries)
    )

    {Map.put(stats, "details_caught_up", length(entries)),
     errors ++ fetch_errors ++ icon_errors ++ upsert_errors ++ detail_errors}
  end

  defp detail_backlog, do: Settings.sync_detail_backlog()

  defp raise_source_error(scope, id, reason) do
    raise "Confluence #{scope} fetch failed#{if id, do: " for #{inspect(id)}"}: #{inspect(reason)}"
  end

  # A snapshot is the only run that sees the whole site, so it is the only run
  # that can notice a space is no longer listed. It does not act on that: a space
  # that disappears from the site's own listing is as likely to be a token that
  # lost access as a space somebody deleted, and the two cannot be told apart
  # from the answer. The run says which spaces it did not find and leaves every
  # row where it is, for an operator — and an empty listing says nothing at all,
  # which is the same guard the per-space page listing gets.
  defp unlisted_spaces([]), do: {0, []}

  defp unlisted_spaces(space_dtos) do
    unlisted = Mirror.spaces_not_listed(Enum.map(space_dtos, & &1.key))

    {length(unlisted), Enum.map(unlisted, &error("space", &1.key, :not_listed_by_the_source))}
  end

  # Everyone has a personal space, and mirroring the sync account's own drafts
  # is rarely what an operator wants, so personal spaces are skipped unless the
  # deployment asks for them (`CM_SYNC_PERSONAL_SPACES=true`). The filter is not
  # only for a whole-site snapshot: an incremental run that finds a new page in
  # somebody's private space must skip it too, or the space arrives through the
  # back door. Syncing one space explicitly still works — that is a request, not
  # a discovery.
  defp importable_spaces(space_dtos) do
    if personal_spaces?() do
      {space_dtos, 0}
    else
      personal = Enum.filter(space_dtos, &(&1[:type] == "personal"))
      {space_dtos -- personal, length(personal)}
    end
  end

  # The same rule for a space the mirror already holds: a personal space that was
  # skipped when the site was listed is not read now because it exists here.
  defp importable_space?(%Space{type: "personal"}), do: personal_spaces?()
  defp importable_space?(%Space{}), do: true

  # A space nobody asked for is not imported, and one that leaves the whitelist
  # is trashed — softly: its rows stay, and naming it again brings it back on the
  # next run. This is the one removal the sync still performs, because it is an
  # operator's decision about configuration rather than an answer from the site
  # (see `unlisted_spaces/1` for the case that only reports).
  defp whitelisted_spaces(space_dtos) do
    case SpaceScope.wanted() do
      :all ->
        {space_dtos, []}

      keys ->
        Enum.split_with(space_dtos, &SpaceScope.import?(keys, &1.key))
    end
  end

  defp trash_outside_whitelist([]), do: {0, 0}

  defp trash_outside_whitelist(dtos) do
    trashed =
      Enum.flat_map(dtos, fn dto ->
        case Mirror.get_space_by_key(dto.key) do
          nil -> []
          space -> [{space, Mirror.trash_space(space)}]
        end
      end)

    Enum.each(trashed, fn {space, pages} ->
      Audit.log(Audit.system_actor(), Space.audit_event_space_deleted(space, pages))
    end)

    {length(trashed), trashed |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
  end

  # `changed_since` only names pages that moved inside the window, so a space the
  # site created outside it — or one whose row was made by a single changed page,
  # whose listing was never read — would wait for a snapshot nobody knew to run.
  # Every run therefore reads the site's space list once and finishes what it
  # finds: a row for a space the mirror has never seen, and a full page listing
  # for every space whose listing has never been read.
  #
  # The pages come in with their bodies (a listing carries `body.storage`), so
  # the space is readable as soon as this returns; comments, attachments and
  # restrictions are the detail backlog's business, at its own bounded rate.
  defp discover_spaces(source, opts) do
    case source.spaces(opts) do
      {:ok, dtos} ->
        {dtos, personal} = importable_spaces(dtos)
        {dtos, outside} = whitelisted_spaces(dtos)
        outside = length(outside)
        listed = Mirror.space_listing_state()

        {unknown, known} = Enum.split_with(dtos, &(not Map.has_key?(listed, &1.key)))
        {new_spaces, icon_errors} = upsert_spaces(source, unknown)

        unlisted =
          known
          |> Enum.map(&listed[&1.key])
          |> Enum.reject(& &1.pages_listed_at)
          |> Enum.filter(&(importable_space?(&1) and SpaceScope.import?(&1.key)))

        spaces = new_spaces ++ unlisted

        if spaces != [] do
          Log.add(
            :info,
            "the site names #{length(spaces)} space(s) this mirror has never listed; reading them now",
            spaces: length(spaces)
          )
        end

        {_entries, counts, listing_errors, absent} = sync_pages_of(spaces, source, opts)

        # `_entries` is deliberate: their pages are readable from the listing
        # body, and rendering them here would make one run cost a snapshot.
        {spaces, counts, icon_errors ++ listing_errors, absent, personal + outside}

      {:error, reason} ->
        # Reported, not swallowed: a mirror that cannot list the site cannot
        # know what it is missing, and the operator should see that in the run.
        {[], %{changed: 0, unchanged: 0}, [error("spaces", nil, reason)], 0, 0}
    end
  end

  # An incremental run only has page DTOs, and a page does not say what kind of
  # space it lives in, so the space list answers for it. A failure to read the
  # list fails the run: silently importing a personal space is worse than a
  # retry.
  defp drop_personal_pages(source, dtos, opts) do
    if personal_spaces?() do
      {dtos, 0}
    else
      case source.spaces(opts) do
        {:ok, space_dtos} ->
          personal =
            space_dtos
            |> Enum.filter(&(&1[:type] == "personal"))
            |> MapSet.new(& &1.key)

          kept = Enum.reject(dtos, &MapSet.member?(personal, &1.space_key))
          {kept, length(dtos) - length(kept)}

        {:error, reason} ->
          raise_source_error(:spaces, nil, reason)
      end
    end
  end

  defp personal_spaces? do
    :confluence_phx_mirror
    |> Application.get_env(:sync, [])
    |> Keyword.get(:personal_spaces, false)
  end

  # ---------------------------------------------------------------------------
  # Spaces and pages
  # ---------------------------------------------------------------------------

  defp upsert_spaces(source, space_dtos) do
    Enum.map_reduce(space_dtos, [], fn dto, errors ->
      {space, icon_errors} = upsert_space(source, dto)
      {space, errors ++ icon_errors}
    end)
  end

  defp upsert_space(source, dto) do
    previous_icon = previous_icon_path(dto.key)
    {:ok, space} = Mirror.upsert_space(space_attrs(dto))

    case mirror_space_icon(source, space, previous_icon) do
      {:ok, space} -> {space, []}
      {:error, reason} -> {space, [error("space", space.key, {:icon, reason})]}
    end
  end

  defp previous_icon_path(key) do
    case Mirror.get_space_by_key(key) do
      nil -> nil
      space -> space.icon_path
    end
  end

  defp space_attrs(dto) do
    %{
      key: dto.key,
      name: dto.name,
      type: dto[:type] || "global",
      description: dto[:description],
      homepage_confluence_id: dto[:homepage_id],
      external_url: dto[:url],
      labels: dto[:labels] || [],
      icon_path: get_in(dto, [:icon, :path]),
      synced_at: now()
    }
  end

  # The icon is content like an attachment: the bytes live in the blob store and
  # the row says where. Confluence versions the upstream path, so an unchanged
  # path whose blob is on disk means there is nothing to fetch. An icon that went
  # away upstream takes its bytes with it.
  defp mirror_space_icon(source, space, previous_path) do
    cond do
      is_nil(space.icon_path) -> forget_space_icon(space)
      not function_exported?(source, :space_icon, 2) -> {:ok, space}
      space.icon_path == previous_path and blob_present?(space.icon_blob_key) -> {:ok, space}
      true -> fetch_space_icon(source, space)
    end
  end

  defp forget_space_icon(%Space{icon_blob_key: nil} = space), do: {:ok, space}

  defp forget_space_icon(space) do
    Store.delete(space.icon_blob_key)

    case update_space_icon(space, %{icon_blob_key: nil, icon_media_type: nil, icon_sha256: nil}) do
      {:ok, space} ->
        Log.add(:debug, "space icon gone upstream: #{space.key}", space: space.key)
        {:ok, space}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp fetch_space_icon(source, space) do
    with {:ok, %{body: bytes, media_type: media_type}} <-
           source.space_icon(%{path: space.icon_path}, []),
         key = Key.space_icon(space.key, media_type),
         {:ok, _key} <- Store.put(key, bytes) do
      # A changed media type changes the extension, and with it the key.
      if space.icon_blob_key && space.icon_blob_key != key, do: Store.delete(space.icon_blob_key)

      attrs = %{
        icon_blob_key: key,
        icon_media_type: media_type,
        icon_sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      }

      case update_space_icon(space, attrs) do
        {:ok, space} ->
          Log.add(:debug, "space icon mirrored: #{space.key}", space: space.key)
          {:ok, space}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp update_space_icon(space, attrs), do: space |> Space.changeset(attrs) |> Repo.update()

  defp blob_present?(nil), do: false
  defp blob_present?(key), do: Store.exists?(key)

  defp ensure_space(source, space_key, opts) do
    case source.spaces(opts) do
      {:ok, space_dtos} ->
        case Enum.find(space_dtos, &(&1.key == space_key)) do
          nil ->
            with {:ok, space} <-
                   Mirror.upsert_space(%{key: space_key, name: space_key, type: "global"}),
                 do: {:ok, space, []}

          dto ->
            {space, icon_errors} = upsert_space(source, dto)
            {:ok, space, icon_errors}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Who may read a space is mirrored when the source can read it. Cloud answers
  # it on the space itself (`?expand=permissions`); a source that cannot is not
  # an error: the space is simply open, exactly as it is for the sync account.
  defp sync_space_permissions(source, spaces) do
    Enum.map_reduce(spaces, [], fn space, errors ->
      case fetch_space_permissions(source, space) do
        {:ok, permissions} ->
          {:ok, _} = Mirror.replace_space_permissions(space, permissions)
          {space, errors}

        :unsupported ->
          {space, errors}

        {:error, reason} ->
          {space, [error("space", space.key, {:space_permissions, reason}) | errors]}
      end
    end)
  end

  defp fetch_space_permissions(source, space) do
    if function_exported?(source, :space_permissions, 2) do
      case source.space_permissions(space.key, []) do
        {:error, :not_supported} -> :unsupported
        other -> other
      end
    else
      :unsupported
    end
  end

  # Groups are how Confluence grants access, so a run settles them **first**:
  # the identities the mirror already knows are refreshed before any content
  # moves. Confluence never lists its users, so `:everyone` here means exactly
  # that — the people the last run's content named. Anyone this run's content
  # introduces is refreshed by a second, smaller pass (`newcomers/1`), which is
  # the closest a Cloud mirror can come to "users first, then spaces".
  #
  # The other direction — "who is in this group" — is `refresh_groups/2`, and it
  # has to wait for the details pass: the groups worth asking about are the ones
  # page restrictions and space permissions refer to, and those land there.
  #
  # Returns how many membership rows were written and which account ids were
  # asked about, so the second pass knows who is left.
  defp sync_groups(source, opts, only \\ :everyone) do
    {refreshed, stored, errors} = refresh_memberships(source, opts, only)
    {stored, errors, refreshed}
  end

  # A snapshot meets a lot of people, and every one of them is a request, so the
  # sweep is capped; the order is stable, so the same people are refreshed.
  # `:people_limit` lifts the cap for a run that was asked about everyone.
  @max_membership_checks 200

  defp refresh_memberships(source, opts, only) do
    limit = Keyword.get(opts, :people_limit, @max_membership_checks)

    if function_exported?(source, :groups_of_account, 2) do
      only
      |> identities_to_refresh(limit)
      |> Enum.reduce({[], 0, []}, fn identity, {refreshed, stored, errors} ->
        {saved, new_errors} = refresh_membership(source, identity, opts)
        {[identity.account_id | refreshed], stored + saved, errors ++ new_errors}
      end)
    else
      # A source that only answers "who is in this group" has nothing to say
      # here; `refresh_groups/2` is its half of the work.
      {[], 0, []}
    end
  end

  defp identities_to_refresh(:everyone, limit), do: capped(Mirror.known_identities(), limit)

  defp identities_to_refresh(%MapSet{} = only, limit) do
    Mirror.known_identities()
    |> Enum.filter(&MapSet.member?(only, &1.account_id))
    |> capped(limit)
  end

  defp capped(identities, :all), do: identities
  defp capped(identities, limit), do: Enum.take(identities, limit)

  defp refresh_membership(source, identity, opts) do
    case source.groups_of_account(identity.account_id, opts) do
      {:ok, groups} ->
        {:ok, stored} = Mirror.replace_subject_groups(identity, groups)
        {stored, []}

      {:error, :not_supported} ->
        {0, []}

      # The account is gone from the site; so is its membership.
      {:error, :not_found} ->
        {:ok, _} = Mirror.replace_subject_groups(identity, [])
        {0, []}

      {:error, reason} ->
        {0, [error("account", identity.account_id, reason)]}
    end
  end

  # The people the content named that the first sweep did not cover.
  defp newcomers(refreshed) do
    known =
      Mirror.known_identities()
      |> Enum.map(& &1.account_id)
      |> MapSet.new()

    MapSet.difference(known, MapSet.new(refreshed))
  end

  defp refresh_groups(source, opts) do
    cond do
      # A group whose members the site pages through is read a page at a time:
      # a group can be the whole staff, and holding it in memory is what breaks
      # a site with hundreds of thousands of people.
      function_exported?(source, :each_group_member_page, 3) -> stream_groups(source, opts)
      function_exported?(source, :group_members, 2) -> list_groups(source, opts)
      true -> {0, []}
    end
  end

  # Every group the site lists, not only the ones the content refers to: a
  # group's membership is how a mirror learns about people who never authored
  # anything and never signed in.
  defp stream_groups(source, opts) do
    case source.groups(opts) do
      {:ok, groups} ->
        groups
        |> Enum.uniq_by(&Mirror.GroupMember.key(&1.name))
        |> Enum.reduce({0, []}, &stream_group(source, &1, &2, opts))

      {:error, reason} ->
        {0, [error("groups", nil, reason)]}
    end
  end

  defp stream_group(source, group, {count, errors}, opts) do
    # The marker every page of this read carries, so the prune at the end drops
    # exactly the people the site no longer lists. Unique per read rather than a
    # timestamp: two runs inside one second still have to tell their rows apart.
    seen_in = System.unique_integer([:positive])
    sink = &Mirror.put_group_members(group.name, &1, seen_in)

    case source.each_group_member_page(group, opts, sink) do
      {:ok, stored} ->
        Mirror.forget_group_members_not_seen_in(group.name, seen_in)
        {count + stored, errors}

      {:error, :not_found} ->
        {:ok, _} = Mirror.replace_group_members(group.name, [])
        {count, errors}

      {:error, :not_supported} ->
        {count, errors}

      {:error, reason} ->
        {count, [error("group", group.name, reason) | errors]}
    end
  end

  defp list_groups(source, opts) do
    groups_to_refresh()
    |> Enum.reduce({0, []}, &refresh_group(source, &1, &2, opts))
  end

  defp groups_to_refresh do
    config_groups = for key <- Admins.admin_groups(), do: {key, key}
    Enum.uniq_by(Mirror.referenced_groups() ++ config_groups, &elem(&1, 1))
  end

  defp refresh_group(source, {name, _key}, {count, errors}, opts) do
    case source.group_members(name, opts) do
      {:ok, members} ->
        {:ok, stored} = Mirror.replace_group_members(name, members)
        {count + stored, errors}

      # The site simply has no such group; that is an empty membership, not a
      # failure a reader should see.
      {:error, :not_found} ->
        {:ok, _} = Mirror.replace_group_members(name, [])
        {count, errors}

      {:error, :not_supported} ->
        {count, errors}

      {:error, reason} ->
        {count, [error("group", name, reason) | errors]}
    end
  end

  defp ensure_spaces_for(source, dtos, opts) do
    keys = dtos |> Enum.map(& &1.space_key) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {spaces, errors} =
      Enum.reduce(keys, {[], []}, fn key, {spaces, errors} ->
        case ensure_space(source, key, opts) do
          {:ok, space, icon_errors} -> {[space | spaces], errors ++ icon_errors}
          {:error, _} -> {spaces, errors}
        end
      end)

    {Enum.reverse(spaces), errors}
  end

  defp sync_pages_of(spaces, source, opts) do
    {entries, counts, errors, absent} =
      Enum.reduce(spaces, {[], %{changed: 0, unchanged: 0}, [], 0}, fn space,
                                                                       {entries, counts, errors,
                                                                        absent} ->
        check_cancelled!(opts)

        case source.pages(space.key, opts) do
          {:ok, dtos} ->
            {upserted, space_counts, page_errors} = upsert_entries(dtos, [space], opts)
            {flagged, guard_errors} = reconcile_deletions(space, dtos)

            # The space is only marked as listed once the whole listing landed:
            # a run stopped halfway leaves it unlisted, and the next run reads it
            # again rather than believing half of it.
            Mirror.mark_space_listed(space)

            counts = add_counts(counts, space_counts)
            record_progress(opts, counts)

            # `Enum.reverse(list, acc)` prepends a whole space at once: `entries
            # ++ upserted` copies every entry of every space before it, which is
            # quadratic in the size of the site (50k pages: 5.8 s of pure copy).
            {Enum.reverse(upserted, entries), counts, errors ++ page_errors ++ guard_errors,
             absent + flagged}

          {:error, reason} ->
            {entries, counts, [error("space", space.key, reason) | errors], absent}
        end
      end)

    {Enum.reverse(entries), counts, errors, absent}
  end

  defp add_counts(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  # `pages` is what the run saw; `changed` is what it had to look at. The gap is
  # the point of an incremental mirror, so it is reported, not hidden.
  defp page_counts(counts) do
    %{
      "pages" => counts.changed + counts.unchanged,
      "changed" => counts.changed,
      "unchanged" => counts.unchanged
    }
  end

  # A source that suddenly lists no pages for a space is far more likely to be
  # a permission or filtering problem than a mass deletion. Confluence export
  # tools guard against exactly this, so an empty listing never wipes a space.
  defp reconcile_deletions(space, [] = _dtos) do
    if Mirror.count_pages(space.id) > 0 do
      {0, [error("space", space.key, :empty_listing_kept_existing_pages)]}
    else
      {0, []}
    end
  end

  # A listing is evidence, not a verdict. It can leave a page out because the
  # page is gone — and just as easily because the token lost access to it, since
  # a page restriction added for the sync account looks exactly like a deletion
  # from here. So the sync flags and a person decides: the page gets
  # `absent_since` (cleared the moment a listing names it again, reviewed on
  # `/admin/upstream`), and nothing is trashed.
  defp reconcile_deletions(space, dtos) do
    {flagged, _cleared} = Mirror.mark_absent(space, Enum.map(dtos, & &1.id))

    {flagged, suspicion(space, length(dtos), flagged)}
  end

  # A listing that names far fewer pages than the mirror holds has the shape of
  # a permission change, not of a mass deletion: a site that really lost
  # hundreds of pages at once is a catastrophe an operator hears about from
  # people, while a token that lost a group looks exactly like this. Saying so in
  # the run's errors is what turns a silent flag into something a person sees.
  @listing_shrank_floor 0.5
  @listing_shrank_minimum 5

  defp suspicion(space, listed, flagged) do
    held = Mirror.count_pages(space.id)

    if held >= @listing_shrank_minimum and listed < held * @listing_shrank_floor do
      [
        error("space", space.key, {
          :listing_shrank,
          listed: listed,
          held: held,
          flagged: flagged,
          hint: "a permission change looks like this; nothing was trashed"
        })
      ]
    else
      []
    end
  end

  # A snapshot of a real site lists hundreds of thousands of pages, so the run
  # is built around not touching them: existing pages are loaded once as a light
  # index, unchanged pages cost one key lookup, and only pages that changed are
  # rendered and asked for their attachments and comments.
  defp upsert_entries(dtos, spaces, opts) do
    by_key = Map.new(spaces, &{&1.key, &1})
    existing = existing_pages(dtos)
    forced = Keyword.get(opts, :force, MapSet.new())

    {entries, counts, errors} =
      Enum.reduce(dtos, {[], %{changed: 0, unchanged: 0}, []}, fn dto,
                                                                  {entries, counts, errors} ->
        if rem(counts.changed + counts.unchanged, @cancel_check_every) == 0 do
          check_cancelled!(opts)
          record_progress(opts, counts)
        end

        case Map.fetch(by_key, dto.space_key) do
          {:ok, space} ->
            case upsert_page_record(space, dto, Map.get(existing, dto.id),
                   force: MapSet.member?(forced, dto.id)
                 ) do
              {:ok, :unchanged} ->
                {entries, Map.update!(counts, :unchanged, &(&1 + 1)), errors}

              {:ok, entry} ->
                {[entry | entries], count_entry(counts, entry), errors}

              {:error, reason} ->
                {entries, counts, [error("page", dto.id, reason) | errors]}
            end

          :error ->
            {entries, counts, [error("page", dto.id, {:unknown_space, dto.space_key}) | errors]}
        end
      end)

    {Enum.reverse(entries), counts, errors}
  end

  # A page re-read only because a comment or a file moved is not a changed page:
  # its content was already current. Counting it as changed is how a quiet site
  # ends up looking busy.
  defp count_entry(counts, %{change: :unchanged}), do: Map.update!(counts, :unchanged, &(&1 + 1))
  defp count_entry(counts, _entry), do: Map.update!(counts, :changed, &(&1 + 1))

  # Only the fields change detection needs: a page body can be megabytes, and
  # keeping 400k of them in memory to compare them would defeat the purpose.
  # Confluence bumps the version on every edit, which is the signal we need.
  # The pages in hand, and only those: a snapshot walks every space, and asking
  # the table for its whole contents once per space is a full scan each time
  # plus a map of the entire mirror held while a handful of ids are looked up.
  # `confluence_id` is unique, so this is one index probe per page listed.
  defp existing_pages(dtos) do
    ids = Enum.map(dtos, & &1.id)

    from(p in Page,
      where: p.confluence_id in ^ids,
      select:
        {p.confluence_id, p.version_number, p.title, p.type, not is_nil(p.body_export),
         p.deleted_at, p.deleted_reason, p.absent_since, p.subtype, p.synced_at}
    )
    |> Repo.all()
    |> Map.new(fn {id, version, title, type, rendered?, deleted_at, reason, absent_since, subtype,
                   synced_at} ->
      current? = is_nil(absent_since) and (is_nil(deleted_at) or reason == "manual")
      {id, light(version, title, type, rendered?, current?, subtype, synced_at)}
    end)
  end

  defp light(version, title, type, rendered?, current?, subtype, synced_at) do
    %{
      version_number: version,
      title: title,
      type: type,
      rendered?: rendered?,
      current?: current?,
      subtype: subtype,
      synced_at: synced_at
    }
  end

  defp light(%Page{} = page) do
    light(
      page.version_number,
      page.title,
      page.type,
      not is_nil(page.body_export),
      is_nil(page.absent_since) and (is_nil(page.deleted_at) or page.deleted_reason == "manual"),
      page.subtype,
      page.synced_at
    )
  end

  defp light(nil), do: nil

  defp upsert_page_record(space, dto, previous, opts) do
    attrs = page_attrs(dto)
    force? = Keyword.get(opts, :force, false)

    case change_of(previous, attrs, force?) do
      :unchanged when not force? ->
        {:ok, :unchanged}

      change ->
        Repo.transaction(fn ->
          page = must!(Mirror.upsert_page(space, attrs))
          page = must!(Mirror.replace_labels(page, dto.labels))
          # Labels and properties are stored before any page renders, so label
          # listings and property reports in a snapshot see the whole run.
          must!(Mirror.replace_properties(page, PageProperties.parse(dto.body.storage)))
          # The version moved, so the details are stale by definition. Clearing
          # the mark in the same transaction is what makes an interrupted
          # detail pass readable again: `pages_awaiting_details` looks for NULL.
          :ok = Mirror.mark_details_stale(page)

          %{
            space: space,
            dto: dto,
            page: page,
            change: change,
            previous_version: previous && previous.version_number
          }
        end)
    end
  end

  defp change_of(nil, _attrs, _force?), do: :created

  defp change_of(previous, attrs, force?) do
    cond do
      # A live doc is edited continuously by design, so its version moves
      # constantly and each move would be a full read, render and detail pass for
      # a body that differs only in the typing. The mirror reads one at most
      # every `sync.live_doc_refresh_seconds` and leaves the copy it has alone
      # until then — which is why a live doc says how old its copy is. A forced
      # read has already happened, so it judges the change it found.
      live_doc_fresh?(previous) and not force? -> :unchanged
      previous.version_number != attrs.version_number -> :updated
      previous.title != attrs.title -> :updated
      previous.type != attrs.type -> :updated
      not previous.rendered? -> :updated
      # A page we hold as absent, or as vanished, is behind the site whatever its
      # version says. Confluence does not bump a version when it restores a page
      # from its trash, and nothing else would ever write that page again — the
      # version test alone leaves it dead for good. Writing it counts as an
      # update, because that is what it is: a record rewritten, with a reason.
      # A page an administrator trashed stays `current?` on purpose: a sync does
      # not undo a person's decision, and rewriting it every run would say it had.
      not previous.current? -> :updated
      true -> :unchanged
    end
  end

  # A page DTO as the row it becomes. Public so the scale fixture
  # (`ConfluencePhxMirror.Synthetic`) can write the same row without the
  # per-page pipeline; keeping one mapping is what stops a benchmark from
  # measuring a table shape no sync ever produces.
  @doc false
  def page_attrs(dto) do
    %{
      confluence_id: dto.id,
      type: dto.type,
      status: dto.status,
      # A source that has no live docs (the demo snapshot, a test double) says
      # nothing, which is the same as "an ordinary page".
      subtype: Map.get(dto, :subtype),
      title: dto.title,
      slug: Page.slugify(dto.title),
      author_name: dto.version.by.display_name,
      author_account_id: dto.version.by.account_id,
      body_storage: dto.body.storage,
      ancestors: dto.ancestors,
      version_number: dto.version.number,
      version_message: dto.version.message,
      external_url: dto.url,
      external_created_at: dto.created_at,
      external_updated_at: dto.updated_at,
      synced_at: now()
    }
  end

  @doc """
  Whether a live doc was read recently enough to leave alone.

  Only a live doc has this problem: Confluence lets several people edit one at a
  time, so its version moves continuously and a mirror that took every move
  would re-read, re-render and re-index a body that differs in the typing — for
  a copy it already tells readers is a snapshot. So a live doc is read at most
  once per `sync.live_doc_refresh_seconds`; an administrator's resync is how
  somebody says "now".

  Takes a page or the light row `change_of/2` works from, and answers `false`
  for anything that is not a rendered live doc.
  """
  @spec live_doc_fresh?(map() | nil) :: boolean()
  def live_doc_fresh?(%{subtype: "live", rendered?: true, synced_at: %DateTime{} = synced_at}) do
    DateTime.diff(now(), synced_at) < Settings.live_doc_refresh_seconds()
  end

  def live_doc_fresh?(_page), do: false

  defp resolve_trees(spaces) do
    Enum.each(Enum.uniq_by(spaces, & &1.id), &Mirror.resolve_parents/1)
  end

  # ---------------------------------------------------------------------------
  # Rendering, labels, links, attachments, comments
  # ---------------------------------------------------------------------------

  defp sync_details(source, entries, index, opts) do
    initial =
      {%{
         "attachments" => 0,
         "attachments_downloaded" => 0,
         "comments" => 0,
         "links" => 0,
         "notifications" => 0
       }, []}

    entries
    |> Task.async_stream(&render_entry(source, &1, index, opts),
      max_concurrency: concurrency(),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(initial, fn
      {:ok, {:ok, page_stats, entry_errors}}, {stats, errors} ->
        {merge_stats(stats, page_stats), errors ++ entry_errors}

      {:ok, {:error, reason, dto}}, {stats, errors} ->
        Log.add(:warn, "page failed: #{dto.title}", page: dto.id, reason: format_error(reason))
        {stats, [error("page", dto.id, reason) | errors]}

      {:exit, reason}, {stats, errors} ->
        {stats, [error("page", nil, {:exit, inspect(reason)}) | errors]}
    end)
  end

  # Detail work is network-bound (one attachments and one comments call per
  # changed page), so a handful run at once; the source's rate limiter still
  # paces the requests.
  defp concurrency, do: Settings.sync_concurrency()

  defp render_entry(source, %{space: space, dto: dto, page: page, change: change}, index, opts) do
    check_cancelled!(opts)

    {attachments, attachment_errors} = mirror_attachments(source, space, page)
    restrictions = fetch_restrictions(source, page)
    attachment_map = Map.new(attachments, &attachment_ref(space, page, &1))

    context = %{
      page: page,
      space_key: space.key,
      base_url: site_origin(dto.url),
      pages: index,
      attachments: attachment_map,
      attachment_lookup: &Mirror.attachment_ref/2
    }

    rendered =
      Renderer.render(Emoticons.from_storage(dto.body.export_view, dto.body.storage), context)

    with {:ok, read} <-
           read_page_details(source, page, rendered, attachments, restrictions),
         # The page comes back from the write as a page; saying so here is what
         # keeps it one for the mailer below instead of a map that happens to
         # have the same keys.
         {:ok, {%Page{} = page, comments, pruned}} <-
           store_details(page, space, read, context, source, opts) do
      # Blobs go after the commit: a crash between the two leaves an
      # unreferenced file, which is harmless, never a row pointing at nothing.
      discard_blobs(pruned)

      # The page is on disk whole, so a tab still reading the old copy can be
      # told — offered a reload, never given one.
      PageUpdates.page_synced(page)

      # The mailer reads `page.space.key`, and the page was read without its
      # space loaded, so it is attached here. Spelled as a struct update, so the
      # page stays a `%Page{}` — for the mailer's own head and for both type
      # checkers, which otherwise see a plain map from here on.
      page = %Page{page | space: space}
      {notifications, notification_errors} = notify(change, page, space)
      audit_change(change, page, space, dto)

      {:ok,
       %{
         "attachments" => length(attachments),
         "attachments_downloaded" => Enum.count(attachments, & &1.downloaded?),
         "comments" => comments.count,
         "links" => length(rendered.links),
         "notifications" => notifications
       },
       attachment_errors ++
         restriction_errors(restrictions, page) ++
         comments.errors ++ notification_errors}
    else
      {:error, reason} -> {:error, reason, dto}
    end
  end

  # Everything the write needs, read before the transaction opens: reading
  # inside it would hold a connection open for the duration of a network call.
  defp read_page_details(source, page, rendered, attachments, restrictions) do
    with {:ok, comment_dtos} <- source.comments(page.confluence_id, []) do
      {:ok,
       %{
         rendered: rendered,
         comments: comment_dtos,
         attachments: attachments,
         restrictions: restrictions
       }}
    end
  end

  # The details of one page, in one transaction. A run can be stopped at any
  # instant (see `run_work/4`), so the page's text, links, comments and the mark
  # that says its details were read move together. The stop is checked here,
  # inside the transaction: what was written before the request is rolled back
  # with it, and the page waits in the backlog for the next run.
  @spec store_details(Page.t(), Space.t(), map(), map(), module(), keyword()) ::
          {:ok, {Page.t(), [Comment.t()], [Attachment.t()]}} | {:error, term()}
  defp store_details(page, space, read, context, source, opts) do
    Repo.transaction(fn ->
      check_cancelled!(opts)

      page = must!(store_rendered_page(page, read.rendered, space, read.attachments))
      must!(Mirror.replace_links(page, read.rendered.links))
      :ok = apply_restrictions(page, read.restrictions)

      comments = must!(store_comments(read.comments, source, space, page, context))

      kept = Enum.map(read.attachments, & &1.confluence_id) ++ comments.attachment_ids
      pruned = delete_attachments(page, kept)

      :ok = Mirror.mark_details_synced(page)
      {page, comments, pruned}
    end)
  end

  defp must!({:ok, value}), do: value
  defp must!({:error, reason}), do: Repo.rollback(reason)

  # A page's read restrictions decide access before its space does, so they are
  # synced per page; a source that cannot read them says nothing at all. The
  # read happens before the page's transaction; the write is inside it.
  defp fetch_restrictions(source, page) do
    if function_exported?(source, :restrictions, 2) do
      source.restrictions(page.confluence_id, [])
    else
      :unsupported
    end
  end

  defp apply_restrictions(_page, :unsupported), do: :ok
  defp apply_restrictions(_page, {:error, _reason}), do: :ok

  defp apply_restrictions(page, {:ok, restrictions}) do
    must!(Mirror.replace_page_restrictions(page, restrictions))
    :ok
  end

  defp restriction_errors({:error, reason}, page),
    do: [error("page", page.confluence_id, {:restrictions, reason})]

  defp restriction_errors(_read, _page), do: []

  # Dynamic macros are resolved from the mirror, so the stored body and its
  # search text both contain what a reader actually sees.
  defp store_rendered_page(page, rendered, space, attachments) do
    export = DynamicContent.expand(rendered.html, %{space: space, page: page})
    text = Renderer.plain_text(export)

    Mirror.update_rendered(page, %{
      body_export: export,
      body_text: text,
      search_text: search_text(text, page, space, attachments),
      synced_at: now()
    })
  end

  # A page's labels or properties change what label listings and property
  # reports show. Expansion is idempotent (the marker stays in the body), so
  # every page carrying a marker is simply re-expanded in place.
  defp refresh_dynamic_pages do
    Enum.each(Mirror.pages_with_dynamic_content(), fn page ->
      export = DynamicContent.expand(page.body_export, %{space: page.space, page: page})
      text = Renderer.plain_text(export)

      Mirror.update_rendered(page, %{
        body_export: export,
        body_text: text,
        search_text: search_text(text, page, page.space, Mirror.attachments(page)),
        synced_at: now()
      })
    end)
  end

  # A page that links a file it does not own can be rendered before the owner's
  # attachments are stored, so a whole-site or whole-space read ends by offering
  # those links a second chance. Only pages whose body names a download path are
  # looked at — a small share of a mirror — and a page whose links all resolved
  # the first time is not written again.
  defp relink_attachment_links do
    Enum.each(Mirror.pages_with_attachment_links(), fn page ->
      base_url = site_origin(page.external_url)

      if base_url do
        context = %{
          page: page,
          space_key: page.space.key,
          base_url: base_url,
          attachments: %{},
          attachment_lookup: &Mirror.attachment_ref/2
        }

        html = Renderer.relink_attachments(page.body_export, context)
        if html != page.body_export, do: Mirror.relink_body_export(page, html)
      end
    end)
  end

  defp notify(:unchanged, _page, _space), do: {0, []}

  defp notify(change, page, _space) do
    results = Notifications.page_changed(page, change)

    notification_errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, reason} -> error("notification", page.confluence_id, reason) end)

    {length(results) - length(notification_errors), notification_errors}
  rescue
    error -> {0, [error("notification", page.confluence_id, Exception.message(error))]}
  end

  # Text search covers every field a reader is likely to remember: body, labels,
  # author, space and attachment filenames. Title is weighted separately by the
  # generated tsvector column.
  #
  # Public so the scale fixture (`ConfluencePhxMirror.Synthetic`) can store the
  # same searchable text without going through the per-page pipeline; a fixture
  # whose pages were only findable by title would make full-text search look
  # like it worked.
  @doc false
  def search_text(body_text, page, space, attachments) do
    [
      body_text,
      Enum.join(page.labels, " "),
      page.author_name,
      space.name,
      space.key,
      Enum.map_join(attachments, " ", & &1.filename)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  # A reference is keyed by the page and the filename, because that is what a
  # download URL names — even for a file that lives in a comment: Confluence's
  # export view rewrites a comment's image to
  # `/download/attachments/<page id>/<file>`, so the page is the owner the
  # markup claims and the id the mirror has to match.
  defp attachment_ref(space, page, attachment) do
    {{page.confluence_id, attachment.filename},
     %{
       confluence_id: attachment.confluence_id,
       page_confluence_id: page.confluence_id,
       space_key: space.key,
       filename: attachment.filename
     }}
  end

  defp mirror_attachments(source, space, page) do
    case source.attachments(page.confluence_id, []) do
      {:ok, attachment_dtos} ->
        {attachments, errors} =
          Enum.map_reduce(attachment_dtos, [], fn dto, errors ->
            case mirror_attachment(source, space, page, dto, nil) do
              {:ok, attachment} -> {attachment, errors}
              {:error, reason} -> {nil, [error("attachment", dto.id, reason) | errors]}
            end
          end)

        {Enum.reject(attachments, &is_nil/1), errors}

      {:error, reason} ->
        {[], [error("attachments", page.confluence_id, reason)]}
    end
  end

  # Attachments deleted in Confluence must disappear from the mirror too. Their
  # rows go in the page's transaction; the blob is removed after it commits, so
  # a crash can only leave an unreferenced file, never a row pointing at a
  # missing one.
  defp delete_attachments(page, kept_confluence_ids) do
    stale =
      Repo.all(
        from a in Attachment,
          where: a.page_id == ^page.id and a.confluence_id not in ^kept_confluence_ids
      )

    Enum.each(stale, fn attachment -> {:ok, _} = Repo.delete(attachment) end)

    stale
  end

  defp discard_blobs(attachments) do
    Enum.each(attachments, fn attachment ->
      if attachment.blob_key, do: Store.delete(attachment.blob_key)

      Log.add(:warn, "attachment pruned: #{attachment.filename}",
        attachment: attachment.confluence_id,
        page: attachment.page_id
      )
    end)
  end

  defp mirror_attachment(source, space, page, dto, comment_id) do
    # Confluence hands out numeric ids on older sites and "att164058" on newer
    # ones; the mirror stores the text form either way.
    confluence_id = to_string(dto.id)
    existing = Repo.get_by(Attachment, confluence_id: confluence_id)

    blob_key = Key.attachment(space.key, page.confluence_id, confluence_id, dto.filename)

    with {:ok, blob_key, downloaded?} <- ensure_blob(source, dto, existing, blob_key) do
      attrs = %{
        confluence_id: confluence_id,
        page_id: page.id,
        comment_id: comment_id,
        filename: dto.filename,
        media_type: dto.media_type,
        byte_size: dto.byte_size,
        version_number: dto.version,
        download_url: dto.download_url,
        blob_key: blob_key,
        sha256: sha256_of(blob_key),
        external_updated_at: dto.updated_at,
        synced_at: now()
      }

      attachment = existing || %Attachment{}

      attachment
      |> Attachment.changeset(attrs)
      |> Repo.insert_or_update()
      |> case do
        {:ok, attachment} ->
          Log.add(:debug, "attachment mirrored: #{dto.filename}",
            attachment: confluence_id,
            page: page.confluence_id,
            downloaded: downloaded?
          )

          {:ok, Map.put(attachment, :downloaded?, downloaded?)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp ensure_blob(source, dto, existing, blob_key) do
    current? =
      existing && existing.blob_key == blob_key && existing.version_number == dto.version &&
        Store.exists?(blob_key)

    if current? do
      {:ok, blob_key, false}
    else
      with {:ok, data} <- source.attachment_data(dto, []),
           {:ok, _key} <- Store.put(blob_key, data) do
        {:ok, blob_key, true}
      end
    end
  end

  defp sha256_of(nil), do: nil

  defp sha256_of(blob_key) do
    case Store.read(blob_key) do
      {:ok, data} -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  # A comment is a row before it is a body: its files belong to it, so the row
  # has to exist before a file can point at it, and the body is rendered once the
  # files are known because the body refers to them.
  # Called inside the page's transaction: the comment rows and bodies, like the
  # page body they annotate, are all-or-nothing.
  defp store_comments(comment_dtos, source, space, page, context) do
    Repo.transaction(fn ->
      {kept, attachment_errors} =
        Enum.reduce(comment_dtos, {[], []}, fn dto, {kept, errors} ->
          comment = upsert_comment(dto, page)
          {files, file_errors} = mirror_comment_files(source, space, page, comment, dto)
          store_comment_body(comment, dto, files, context, space, page)

          {kept ++ Enum.map(Map.get(dto, :attachments, []), &to_string(&1.id)),
           errors ++ file_errors}
        end)

      delete_stale_comments(page, comment_dtos)

      %{count: length(comment_dtos), attachment_ids: kept, errors: attachment_errors}
    end)
  end

  defp upsert_comment(dto, page) do
    attrs = %{
      confluence_id: dto.id,
      page_id: page.id,
      author_name: dto.author,
      author_account_id: Map.get(dto, :author_account_id),
      external_url: dto.url,
      external_created_at: dto.created_at,
      version_number: Map.get(dto, :version_number),
      external_updated_at: Map.get(dto, :updated_at),
      synced_at: now()
    }

    comment = Repo.get_by(Comment, confluence_id: dto.id) || %Comment{}

    {:ok, comment} =
      comment
      |> Comment.changeset(attrs)
      |> Repo.insert_or_update()

    resolve_comment_parent(comment, dto.parent_id)
    comment
  end

  defp mirror_comment_files(source, space, page, comment, dto) do
    {files, errors} =
      Enum.map_reduce(Map.get(dto, :attachments, []), [], fn file, errors ->
        case mirror_attachment(source, space, page, file, comment.id) do
          {:ok, attachment} -> {attachment, errors}
          {:error, reason} -> {nil, [error("attachment", file.id, reason) | errors]}
        end
      end)

    {Enum.reject(files, &is_nil/1), errors}
  end

  # A comment's files are resolved the same way its own markup resolves them:
  # under the page. The page's own file of the same name wins, which is what
  # Confluence's download route answers for the page too.
  defp store_comment_body(comment, dto, files, context, space, page) do
    refs = Map.new(files, &attachment_ref(space, page, &1))

    rendered =
      Renderer.render(
        Emoticons.from_storage(dto.body_export, Map.get(dto, :body_storage)),
        %{
          context
          | attachments: Map.merge(refs, context.attachments)
        }
      )

    {:ok, _} =
      comment
      |> Ecto.Changeset.change(body_export: rendered.html, body_text: rendered.text)
      |> Repo.update()

    :ok
  end

  defp delete_stale_comments(page, comments) do
    ids = Enum.map(comments, & &1.id)

    from(c in Comment, where: c.page_id == ^page.id and c.confluence_id not in ^ids)
    |> Repo.delete_all()
  end

  defp resolve_comment_parent(_comment, nil), do: :ok

  defp resolve_comment_parent(comment, parent_confluence_id) do
    case Repo.get_by(Comment, confluence_id: parent_confluence_id) do
      nil -> :ok
      parent -> comment |> Ecto.Changeset.change(parent_id: parent.id) |> Repo.update()
    end
  end

  defp audit_change(:unchanged, _page, _space, _dto), do: :ok

  # One line per changed page: the audit log keeps the run, the live log keeps
  # the detail an operator greps for when a single page looks wrong.
  defp audit_change(change, page, space, _dto) do
    Log.add(:info, "page #{change}: #{page.title}",
      page: page.confluence_id,
      space: space.key,
      version: page.version_number
    )
  end

  defp merge_stats(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  # ---------------------------------------------------------------------------
  # Sync run bookkeeping
  # ---------------------------------------------------------------------------

  # A run says why it happened as well as what it did: the trigger is what a
  # reader asks a sync first, and a run nobody asked for has none to show.
  defp start_run(source, mode, actor, trigger, opts) do
    # The traffic account covers one run: every call this run makes is counted
    # here and reported when it ends, so a reader never sees yesterday's totals.
    Traffic.reset()

    {:ok, run} =
      %SyncRun{}
      |> SyncRun.changeset(%{
        source: source.name(),
        mode: mode_to_string(mode),
        scope: scope_of(mode, opts),
        trigger: trigger,
        job_id: opts[:job_id],
        status: "running",
        started_at: now()
      })
      |> Repo.insert()

    Audit.log(
      actor,
      SyncRun.audit_event_started(run, mode, source.name(),
        site: Sites.url(),
        trigger: trigger
      )
    )

    run
  end

  defp finish_run(run, stats, errors, actor, trigger) do
    status = if errors == [], do: "succeeded", else: "partial"

    # The run's own numbers are its window; this is the mirror those numbers
    # were compared against, so "1 listed" can be read next to its real size.
    stats =
      stats
      |> Map.put("total", Mirror.count_pages())
      |> Map.put("errors", normalize_errors(errors))

    {:ok, run} =
      run
      |> SyncRun.changeset(%{
        status: status,
        finished_at: now(),
        stats: stats,
        error: errors |> List.first() |> format_error()
      })
      |> Repo.update()

    Audit.log(actor, SyncRun.audit_event_finished(run, trigger: trigger))

    # The home page prints the mirror's totals; the reader who arrives after a
    # sync should not be the one who pays for the scans it made stale.
    ConfluencePhxMirror.Mirror.Counters.warm()

    Logger.info("sync finished",
      sync_run_id: run.id,
      mode: run.mode,
      source: run.source,
      status: status,
      pages: stats["pages"] || 0,
      attachments: stats["attachments"] || 0,
      errors: length(errors)
    )

    Log.add(
      if(errors == [], do: :info, else: :warn),
      "finished a #{run.mode} sync: " <>
        listing_sentence(stats) <>
        "#{stats["attachments"] || 0} attachments, " <>
        "#{stats["total"]} pages in the mirror, #{length(errors)} errors",
      sync_run_id: run.id
    )

    log_traffic_summary()

    Log.current_run(nil)

    {:ok, run}
  end

  # "1 pages" beside "1 skipped" reads like a lie, because it is one item counted
  # twice under two names. A run says what it listed, how that split, whose
  # details it read, and how big the mirror it compared against is.
  defp listing_sentence(%{"pages" => listed} = stats) when is_integer(listed) do
    "#{listed} listed (#{stats["changed"] || 0} changed, " <>
      "#{stats["unchanged"] || 0} unchanged), " <> details_sentence(stats) <> ", "
  end

  defp listing_sentence(_stats), do: ""

  # The details a run read get their own clause, because a run can spend itself
  # on the backlogs and list nothing: "0 re-read for comments and files" is the
  # account of a run that read exactly those for two hundred pages.
  defp details_sentence(stats) do
    ["#{stats["details_relisted"] || 0} re-read for comments and files" | caught_up_clause(stats)]
    |> Enum.join(", ")
  end

  defp caught_up_clause(%{"details_caught_up" => caught})
       when is_integer(caught) and caught > 0,
       do: ["#{caught} caught up from the backlog"]

  defp caught_up_clause(_stats), do: []

  defp fail_run(run, message, trigger) do
    {:ok, run} =
      run
      |> SyncRun.changeset(%{status: "failed", finished_at: now(), error: message})
      |> Repo.update()

    Log.add(:error, "sync failed: #{message}", sync_run_id: run.id, trigger: trigger)
    log_traffic_summary()
    Log.current_run(nil)

    Audit.log(Audit.system_actor(), SyncRun.audit_event_failed(run, message, trigger: trigger))
  end

  # The lines above are the detail; this is the account. A run that never
  # touched the network (the demo snapshot) has nothing to report.
  defp log_traffic_summary do
    traffic = Traffic.summary()

    if traffic.requests > 0 do
      Log.add(:info, "http: " <> Traffic.describe(traffic),
        kind: :http_summary,
        answers: Traffic.answers(traffic)
      )
    end
  end

  defp normalize_errors(errors) do
    errors
    |> Enum.map(fn err ->
      %{"scope" => err.scope, "id" => err.id, "reason" => format_error(err.reason)}
    end)
  end

  defp error(scope, id, reason), do: %{scope: scope, id: id, reason: reason}

  defp format_error(nil), do: nil
  defp format_error(%{reason: reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp mode_to_string(:snapshot), do: "snapshot"
  defp mode_to_string(:incremental), do: "incremental"
  defp mode_to_string(:space), do: "space"
  defp mode_to_string(:people), do: "people"
  defp mode_to_string(:page), do: "page"

  # What a run covers. The mode says how it was asked for and the scope says
  # what that amounts to — one space's key, one page's id — so a run of a space
  # can be read without opening the job that asked for it.
  defp scope_of(:space, opts), do: "space #{Keyword.fetch!(opts, :space_key)}"
  defp scope_of(:page, opts), do: "page #{Keyword.fetch!(opts, :confluence_id)}"
  defp scope_of(:people, _opts), do: "people and groups"
  defp scope_of(_mode, _opts), do: "whole site"

  defp default_since do
    # The cadence, not a constant: a run at the schedule's own interval cannot
    # leave a page between two of them.
    interval = Settings.sync_interval_seconds()
    lookback = Settings.sync_lookback_seconds()
    DateTime.add(DateTime.utc_now(), -max(interval, lookback), :second)
  end

  defp site_origin(nil), do: nil

  defp site_origin(url) do
    uri = URI.parse(url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
