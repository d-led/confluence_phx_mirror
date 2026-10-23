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
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page, Space}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sites
  alias Oban.Job

  alias ConfluencePhxMirror.Sync.{
    Cancelled,
    DynamicContent,
    Gate,
    Log,
    PageProperties,
    Renderer,
    SyncRun
  }

  @type mode :: :snapshot | :incremental | :space | :page
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
  """
  @spec run(mode(), keyword()) :: report()
  def run(mode, opts \\ []) do
    # A `running` row whose owner is gone is not a run in flight. Clear those
    # before taking the lock, because while we hold it we cannot tell ours from
    # anyone else's.
    abandon_abandoned_runs()

    case Gate.exclusive(fn gate_owner ->
           run_locked(mode, Keyword.put(opts, :gate_owner, gate_owner))
         end) do
      {:ok, result} -> result
      {:error, :already_running} = busy -> busy
    end
  end

  defp run_locked(mode, opts) do
    source = Keyword.get(opts, :source, Source.source())
    actor = Keyword.get(opts, :actor, {:system, "sync"})
    trigger = Keyword.get(opts, :trigger)
    # One mirror holds one site's content; never let a sync write across sites.
    Sites.verify!()
    run = start_run(source, mode, actor, trigger)
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

    try do
      {stats, errors} = do_run(mode, source, opts)
      {stats, errors} = reconcile_accounts(mode, source, stats, errors, opts)
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

  # ---------------------------------------------------------------------------
  # One run at a time, and stopping one
  # ---------------------------------------------------------------------------

  @abandoned "the process running this sync stopped before it finished"

  @doc """
  Asks a running sync to stop at its next safe boundary.

  Returns `{:error, :not_running}` when there is nothing to stop — a run that
  already finished, or one that never started. The request is a flag the run
  checks between pages; it is not a kill, so the answer to "has it stopped?"
  is the run's status, not this call.
  """
  @spec cancel(Ecto.UUID.t() | integer(), Audit.actor()) ::
          {:ok, SyncRun.t()} | {:error, :not_running}
  def cancel(run_id, actor) do
    case Repo.get(SyncRun, run_id) do
      %SyncRun{status: "running"} = run ->
        {:ok, run} =
          run
          |> SyncRun.changeset(%{cancel_requested_at: now()})
          |> Repo.update()

        Log.add(:warn, "cancellation requested, stopping at the next page",
          sync_run_id: run.id,
          by: actor_name(actor)
        )

        {:ok, run}

      _finished_or_missing ->
        {:error, :not_running}
    end
  end

  @doc """
  Marks `running` rows as failed when no one holds the sync lock.

  A run outlives its row only while its node holds the advisory lock (see
  `Sync.Gate`), so a free lock plus a running row means the node that owned it
  died — a deploy, an OOM kill, a Machine going away. Saying so beats leaving a
  run that looks busy forever, and beats a timeout that would have to guess.

  Returns how many runs it closed.
  """
  @spec abandon_abandoned_runs() :: non_neg_integer()
  def abandon_abandoned_runs do
    if Gate.held?() do
      0
    else
      from(r in SyncRun, where: r.status == "running")
      |> Repo.all()
      |> Enum.map(&abandon_run/1)
      |> length()
    end
  end

  defp abandon_run(run) do
    {:ok, run} =
      run
      |> SyncRun.changeset(%{status: "failed", finished_at: now(), error: @abandoned})
      |> Repo.update()

    Log.add(:warn, "sync #{run.id} was abandoned: #{@abandoned}", sync_run_id: run.id)
    Audit.log(Audit.system_actor(), SyncRun.audit_event_abandoned(run))
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
  @cancel_check_every 100

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
    case opts[:run_id] do
      nil ->
        :ok

      run_id ->
        Repo.update_all(from(r in SyncRun, where: r.id == ^run_id),
          set: [stats: counts |> page_counts() |> Map.put("phase", "pages")]
        )
    end
  end

  # Which step the run is on now. One read and one write per step, a handful per
  # run — the counts themselves are written as they change, above.
  defp record_phase(opts, phase) do
    with run_id when not is_nil(run_id) <- opts[:run_id],
         %SyncRun{} = run <- Repo.get(SyncRun, run_id) do
      Repo.update_all(from(r in SyncRun, where: r.id == ^run_id),
        set: [stats: Map.put(run.stats || %{}, "phase", phase)]
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
      account_ids()
      |> Enum.reduce({0, []}, fn id, acc -> check_account(source, id, acc, opts) end)
    else
      {0, []}
    end
  end

  defp account_ids do
    (Accounts.account_ids() ++ Mirror.member_account_ids() ++ Mirror.account_ids())
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.take(@max_account_checks)
  end

  defp check_account(source, account_id, {checked, errors}, opts) do
    case source.user_status(account_id, opts) do
      {:ok, status} ->
        Accounts.reconcile_site_status(
          account_id,
          Map.get(status, :email),
          site_state(Map.get(status, :account_status))
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
        {spaces, icon_errors} = upsert_spaces(source, space_dtos)
        {spaces_trashed, pages_trashed} = trash_missing_spaces(space_dtos)
        {spaces, permission_errors} = sync_space_permissions(source, spaces)

        {entries, counts, errors, deleted} = sync_pages_of(spaces, source, opts)
        resolve_trees(spaces)
        index = Mirror.page_index()

        record_phase(opts, "people")
        {new_people, newcomer_errors, _} = sync_groups(source, opts, newcomers(refreshed))
        record_phase(opts, "details")
        {stats, detail_errors} = sync_details(source, entries, index, opts)

        # Restrictions and permissions are in by now, so the groups the content
        # depends on can finally be asked about.
        record_phase(opts, "groups")
        {group_rows, group_errors} = refresh_groups(source, opts)

        stats =
          Map.merge(stats, %{
            "spaces" => length(spaces),
            "skipped_spaces" => skipped,
            "deleted" => deleted,
            "spaces_trashed" => spaces_trashed,
            "pages_trashed" => pages_trashed,
            "group_members" => people + new_people + group_rows
          })
          |> Map.merge(page_counts(counts))

        {stats,
         errors ++
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
      {entries, counts, errors, deleted} = sync_pages_of([space], source, opts)
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
        Map.merge(stats, %{"spaces" => 1, "deleted" => deleted, "group_members" => members})
        |> Map.merge(page_counts(counts))

      {stats,
       errors ++
         icon_errors ++
         permission_errors ++
         people_errors ++ newcomer_errors ++ detail_errors ++ group_errors}
    end
  end

  defp do_run(:page, source, opts) do
    confluence_id = Keyword.fetch!(opts, :confluence_id)
    previous = Page |> Repo.get_by(confluence_id: confluence_id) |> light()

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

  defp do_run(:incremental, source, opts) do
    since = Keyword.get(opts, :since, default_since(source))

    case source.changed_since(since, opts) do
      {:ok, dtos} ->
        # A page in a personal space is not imported through the side door.
        {dtos, skipped_personal} = drop_personal_pages(source, dtos, opts)

        record_phase(opts, "people")
        {people, people_errors, refreshed} = sync_groups(source, opts)
        record_phase(opts, "spaces")
        {spaces, icon_errors} = ensure_spaces_for(source, dtos, opts)
        {spaces, permission_errors} = sync_space_permissions(source, spaces)
        {entries, counts, errors} = upsert_entries(dtos, spaces, opts)
        resolve_trees(spaces)
        index = Mirror.page_index()

        record_phase(opts, "people")
        {new_people, newcomer_errors, _} = sync_groups(source, opts, newcomers(refreshed))
        record_phase(opts, "details")
        {stats, detail_errors} = sync_details(source, entries, index, opts)
        record_phase(opts, "groups")
        {group_rows, group_errors} = refresh_groups(source, opts)

        stats =
          Map.merge(stats, %{
            "spaces" => length(spaces),
            "skipped_personal" => skipped_personal,
            "group_members" => people + new_people + group_rows
          })
          |> Map.merge(page_counts(counts))

        {stats,
         errors ++
           icon_errors ++
           permission_errors ++
           people_errors ++ newcomer_errors ++ detail_errors ++ group_errors}

      {:error, :not_supported} ->
        do_run(:snapshot, source, opts)

      {:error, reason} ->
        raise_source_error(:changed_since, since, reason)
    end
  end

  defp raise_source_error(scope, id, reason) do
    raise "Confluence #{scope} fetch failed#{if id, do: " for #{inspect(id)}"}: #{inspect(reason)}"
  end

  # A snapshot is the only run that sees the whole site, so it is the only run
  # that can tell a space was deleted. It trashes rather than deletes, and it
  # trashes nothing from an empty listing: no spaces at all is a permission or
  # configuration problem far more often than an empty site, which is the same
  # guard the per-space page listing gets.
  defp trash_missing_spaces([]), do: {0, 0}

  defp trash_missing_spaces(space_dtos) do
    trashed = Mirror.prune_missing_spaces(Enum.map(space_dtos, & &1.key))

    Enum.each(trashed, fn {space, pages} ->
      Audit.log(Audit.system_actor(), Space.audit_event_space_deleted(space, pages))
    end)

    {length(trashed), trashed |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
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

  # Who may read a space is mirrored when the source can read it. Confluence
  # Cloud cannot (space permissions are writes only), and that is not an error:
  # the space is simply open, exactly as it is for the sync account.
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
    refresh_memberships(source, opts, only)
  end

  # A snapshot meets a lot of people, and every one of them is a request, so the
  # sweep is capped; the order is stable, so the same people are refreshed.
  @max_membership_checks 200

  defp refresh_memberships(source, opts, only) do
    if function_exported?(source, :groups_of_account, 2) do
      only
      |> identities_to_refresh()
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

  defp identities_to_refresh(:everyone) do
    Mirror.known_identities() |> Enum.take(@max_membership_checks)
  end

  defp identities_to_refresh(%MapSet{} = only) do
    Mirror.known_identities()
    |> Enum.filter(&MapSet.member?(only, &1.account_id))
    |> Enum.take(@max_membership_checks)
  end

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
    if function_exported?(source, :group_members, 2) do
      groups_to_refresh()
      |> Enum.reduce({0, []}, &refresh_group(source, &1, &2, opts))
    else
      {0, []}
    end
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
    Enum.reduce(spaces, {[], %{changed: 0, unchanged: 0}, [], 0}, fn space,
                                                                     {entries, counts, errors,
                                                                      deleted} ->
      check_cancelled!(opts)

      case source.pages(space.key, opts) do
        {:ok, dtos} ->
          {upserted, space_counts, page_errors} = upsert_entries(dtos, [space], opts)
          {deleted_count, guard_errors} = reconcile_deletions(space, dtos)

          if deleted_count > 0 do
            Audit.log(Audit.system_actor(), Space.audit_event_pages_deleted(space, deleted_count))
          end

          counts = add_counts(counts, space_counts)
          record_progress(opts, counts)

          {entries ++ upserted, counts, errors ++ page_errors ++ guard_errors,
           deleted + deleted_count}

        {:error, reason} ->
          {entries, counts, [error("space", space.key, reason) | errors], deleted}
      end
    end)
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

  defp reconcile_deletions(space, dtos) do
    {Mirror.mark_missing_deleted(space, Enum.map(dtos, & &1.id)), []}
  end

  # A snapshot of a real site lists hundreds of thousands of pages, so the run
  # is built around not touching them: existing pages are loaded once as a light
  # index, unchanged pages cost one key lookup, and only pages that changed are
  # rendered and asked for their attachments and comments.
  defp upsert_entries(dtos, spaces, opts) do
    by_key = Map.new(spaces, &{&1.key, &1})
    existing = existing_pages()

    {entries, counts, errors} =
      Enum.reduce(dtos, {[], %{changed: 0, unchanged: 0}, []}, fn dto,
                                                                  {entries, counts, errors} ->
        if rem(counts.changed + counts.unchanged, @cancel_check_every) == 0 do
          check_cancelled!(opts)
          record_progress(opts, counts)
        end

        case Map.fetch(by_key, dto.space_key) do
          {:ok, space} ->
            case upsert_page_record(space, dto, Map.get(existing, dto.id)) do
              {:ok, :unchanged} ->
                {entries, Map.update!(counts, :unchanged, &(&1 + 1)), errors}

              {:ok, entry} ->
                {[entry | entries], Map.update!(counts, :changed, &(&1 + 1)), errors}

              {:error, reason} ->
                {entries, counts, [error("page", dto.id, reason) | errors]}
            end

          :error ->
            {entries, counts, [error("page", dto.id, {:unknown_space, dto.space_key}) | errors]}
        end
      end)

    {Enum.reverse(entries), counts, errors}
  end

  # Only the fields change detection needs: a page body can be megabytes, and
  # keeping 400k of them in memory to compare them would defeat the purpose.
  # Confluence bumps the version on every edit, which is the signal we need.
  defp existing_pages do
    from(p in Page,
      select: {p.confluence_id, p.version_number, p.title, p.type, not is_nil(p.body_export)}
    )
    |> Repo.all()
    |> Map.new(fn {id, version, title, type, rendered?} ->
      {id, light(version, title, type, rendered?)}
    end)
  end

  defp light(version, title, type, rendered?),
    do: %{version_number: version, title: title, type: type, rendered?: rendered?}

  defp light(%Page{} = page),
    do: light(page.version_number, page.title, page.type, not is_nil(page.body_export))

  defp light(nil), do: nil

  defp upsert_page_record(space, dto, previous, opts \\ []) do
    attrs = page_attrs(dto)
    force? = Keyword.get(opts, :force, false)

    case change_of(previous, attrs) do
      :unchanged when not force? ->
        {:ok, :unchanged}

      change ->
        with {:ok, page} <- Mirror.upsert_page(space, attrs),
             {:ok, page} <- Mirror.replace_labels(page, dto.labels) do
          # Labels and properties are stored before any page renders, so label
          # listings and property reports in a snapshot see the whole run.
          {:ok, _properties} =
            Mirror.replace_properties(page, PageProperties.parse(dto.body.storage))

          {:ok,
           %{
             space: space,
             dto: dto,
             page: page,
             change: change,
             previous_version: previous && previous.version_number
           }}
        end
    end
  end

  defp change_of(nil, _attrs), do: :created

  defp change_of(previous, attrs) do
    cond do
      previous.version_number != attrs.version_number -> :updated
      previous.title != attrs.title -> :updated
      previous.type != attrs.type -> :updated
      not previous.rendered? -> :updated
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

  defp resolve_trees(spaces) do
    Enum.each(Enum.uniq_by(spaces, & &1.id), &Mirror.resolve_parents/1)
  end

  # ---------------------------------------------------------------------------
  # Rendering, labels, links, attachments, comments
  # ---------------------------------------------------------------------------

  defp sync_details(source, entries, index, _opts) do
    initial =
      {%{
         "attachments" => 0,
         "attachments_downloaded" => 0,
         "comments" => 0,
         "links" => 0,
         "notifications" => 0
       }, []}

    entries
    |> Task.async_stream(&render_entry(source, &1, index),
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
  defp concurrency do
    :confluence_phx_mirror
    |> Application.get_env(Source.source(), [])
    |> Keyword.get(:sync_concurrency, 4)
  end

  defp render_entry(source, %{space: space, dto: dto, page: page, change: change}, index) do
    {attachments, attachment_errors} = mirror_attachments(source, space, page)
    restriction_errors = mirror_page_restrictions(source, page)
    attachment_map = Map.new(attachments, &attachment_ref(space, page, &1))

    context = %{
      page: page,
      space_key: space.key,
      base_url: site_origin(dto.url),
      pages: index,
      attachments: attachment_map
    }

    rendered = Renderer.render(dto.body.export_view, context)

    with {:ok, page} <- store_rendered_page(page, rendered, space, attachments),
         {:ok, _} <- Mirror.replace_links(page, rendered.links),
         {:ok, comments} <- mirror_comments(source, page, context) do
      page = Map.put(page, :space, space)
      {notifications, notification_errors} = notify(change, page, space)
      audit_change(change, page, space, dto)

      {:ok,
       %{
         "attachments" => length(attachments),
         "attachments_downloaded" => Enum.count(attachments, & &1.downloaded?),
         "comments" => comments,
         "links" => length(rendered.links),
         "notifications" => notifications
       }, attachment_errors ++ restriction_errors ++ notification_errors}
    else
      {:error, reason} -> {:error, reason, dto}
    end
  end

  # A page's read restrictions decide access before its space does, so they are
  # synced per page; a source that cannot read them says nothing at all.
  defp mirror_page_restrictions(source, page) do
    case fetch_restrictions(source, page) do
      {:ok, restrictions} ->
        {:ok, _} = Mirror.replace_page_restrictions(page, restrictions)
        []

      :unsupported ->
        []

      {:error, reason} ->
        [error("page", page.confluence_id, {:restrictions, reason})]
    end
  end

  defp fetch_restrictions(source, page) do
    if function_exported?(source, :restrictions, 2) do
      source.restrictions(page.confluence_id, [])
    else
      :unsupported
    end
  end

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

  defp attachment_ref(space, page, attachment) do
    {attachment.filename,
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
            case mirror_attachment(source, space, page, dto) do
              {:ok, attachment} -> {attachment, errors}
              {:error, reason} -> {nil, [error("attachment", dto.id, reason) | errors]}
            end
          end)

        {Enum.reject(attachments, &is_nil/1),
         errors ++ prune_attachments(page, Enum.map(attachment_dtos, &to_string(&1.id)))}

      {:error, reason} ->
        {[], [error("attachments", page.confluence_id, reason)]}
    end
  end

  # Attachments deleted in Confluence must disappear from the mirror too; the
  # blob is removed first so a failed delete leaves a row pointing at nothing
  # instead of an orphaned file.
  defp prune_attachments(page, kept_confluence_ids) do
    stale =
      Repo.all(
        from a in Attachment,
          where: a.page_id == ^page.id and a.confluence_id not in ^kept_confluence_ids
      )

    Enum.each(stale, fn attachment ->
      if attachment.blob_key, do: Store.delete(attachment.blob_key)
      {:ok, _} = Repo.delete(attachment)

      Log.add(:warn, "attachment pruned: #{attachment.filename}",
        attachment: attachment.confluence_id,
        page: page.confluence_id
      )
    end)

    []
  end

  defp mirror_attachment(source, space, page, dto) do
    # Confluence hands out numeric ids on older sites and "att164058" on newer
    # ones; the mirror stores the text form either way.
    confluence_id = to_string(dto.id)
    existing = Repo.get_by(Attachment, confluence_id: confluence_id)

    blob_key = Key.attachment(space.key, page.confluence_id, confluence_id, dto.filename)

    with {:ok, blob_key, downloaded?} <- ensure_blob(source, dto, existing, blob_key) do
      attrs = %{
        confluence_id: confluence_id,
        page_id: page.id,
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

  defp mirror_comments(source, page, context) do
    case source.comments(page.confluence_id, []) do
      {:ok, comments} ->
        ids = Enum.map(comments, & &1.id)

        Repo.transaction(fn ->
          Enum.each(comments, fn dto ->
            rendered = Renderer.render(dto.body_export, %{context | page: page})

            attrs = %{
              confluence_id: dto.id,
              page_id: page.id,
              author_name: dto.author,
              body_export: rendered.html,
              body_text: rendered.text,
              external_url: dto.url,
              external_created_at: dto.created_at,
              synced_at: now()
            }

            comment =
              Repo.get_by(Comment, confluence_id: dto.id) || %Comment{}

            {:ok, comment} =
              comment
              |> Comment.changeset(attrs)
              |> Repo.insert_or_update()

            resolve_comment_parent(comment, dto.parent_id)
          end)

          from(c in Comment,
            where: c.page_id == ^page.id and c.confluence_id not in ^ids
          )
          |> Repo.delete_all()
        end)

        {:ok, length(comments)}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp start_run(source, mode, actor, trigger) do
    # The traffic account covers one run: every call this run makes is counted
    # here and reported when it ends, so a reader never sees yesterday's totals.
    Traffic.reset()

    {:ok, run} =
      %SyncRun{}
      |> SyncRun.changeset(%{
        source: source.name(),
        mode: mode_to_string(mode),
        status: "running",
        started_at: now(),
        stats: %{}
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

    stats = Map.put(stats, "errors", normalize_errors(errors))

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
      "finished a #{run.mode} sync: #{stats["pages"] || 0} pages, " <>
        "#{stats["attachments"] || 0} attachments, #{length(errors)} errors",
      sync_run_id: run.id
    )

    log_traffic_summary()

    Log.current_run(nil)

    {:ok, run}
  end

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
  defp mode_to_string(:space), do: "incremental"
  defp mode_to_string(:page), do: "webhook"

  defp default_since(source) do
    interval =
      Application.get_env(:confluence_phx_mirror, source, [])
      |> Keyword.get(:sync_interval_seconds, 0)

    lookback = Application.get_env(:confluence_phx_mirror, :sync, [])[:lookback_seconds] || 3600
    DateTime.add(DateTime.utc_now(), -max(interval, lookback), :second)
  end

  defp site_origin(nil), do: nil

  defp site_origin(url) do
    uri = URI.parse(url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
