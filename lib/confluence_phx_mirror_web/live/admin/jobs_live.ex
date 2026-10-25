defmodule ConfluencePhxMirrorWeb.Admin.JobsLive do
  @moduledoc """
  Oban's rows, in every state — including the ones the queue on the overview
  hides.

  The overview's queue answers "what will run next" for syncs, because a sync
  that has not started can still be prevented. This page answers the question a
  deploy leaves behind, for every worker: Oban's own rows, whatever state they
  are in. A job whose node died stays `executing` for ever — the queue never
  lists it, nothing reports it finishing, and it holds one of the queue's slots
  — so it has to be visible somewhere, next to a button that stops it.

  The page knows Oban and nothing else. What a job is *doing* comes from the
  record its worker writes, through `ConfluencePhxMirror.Jobs.Progress`: the
  status word and its colour, one line of progress, the failure behind it, and
  where its log is. A sync is the first kind of job with such a record, not the
  only kind this page can show.

  For the same reason the row is built from what every job has — its worker,
  its arguments, its state and its attempts — and not from what today's workers
  happen to mean. The **Scope** column is the arguments read back to the
  reader ("space MFS", "mode snapshot"), so a worker this page has never heard
  of still says what it acts on; a job that takes none says so instead of
  leaving a blank. Who asked lives under the worker's name, the way the sync
  table carries the trigger under its mode.

  It is admin-only, like every screen under `/admin`, and it is not dev-only on
  purpose: leftover jobs are made by deploys, and the deploy that matters is the
  production one. It refreshes itself while open, because the state it shows is
  exactly the thing that changes without anyone touching the page.
  """

  use ConfluencePhxMirrorWeb, :live_view

  import ConfluencePhxMirrorWeb.AdminComponents
  import ConfluencePhxMirrorWeb.UIComponents

  alias ConfluencePhxMirror.Jobs
  alias ConfluencePhxMirror.Jobs.Progress
  alias ConfluencePhxMirrorWeb.Time

  @refresh_ms 5_000

  # Whole-site runs are measured at 1 h 37 to 1 h 50. A job still executing far
  # beyond that is a leftover from a restart rather than work in progress — but
  # it is a label, not a decision: only an operator can say which it is.
  @longest_run_minutes 180

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(
       page_title: "Jobs",
       state: "all",
       state_options: state_options(),
       now: DateTime.utc_now()
     )
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"state" => state}, socket) do
    {:noreply, socket |> assign(:state, state) |> load()}
  end

  def handle_event("cancel", %{"id" => id}, socket) do
    case Jobs.cancel(String.to_integer(id), {:user, socket.assigns.current_user}) do
      {:ok, job} ->
        {:noreply,
         socket
         |> put_flash(:info, "Cancelled job ##{job.id}: Oban will not run it again.")
         |> load()}

      {:error, :settled} ->
        {:noreply,
         socket
         |> put_flash(:error, "Job ##{id} had already finished — nothing was cancelled.")
         |> load()}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:noreply, socket |> assign(:now, DateTime.utc_now()) |> load()}
  end

  defp load(socket) do
    jobs = Jobs.list(socket.assigns.state)
    work = Jobs.work_of(Enum.map(jobs, & &1.id))

    assign(socket,
      rows: rows(jobs, work),
      unfinished: Enum.count(jobs, &(&1.state in Jobs.unfinished_states()))
    )
  end

  defp state_options do
    [{"all", "Every state"} | Enum.map(Jobs.states(), &{&1, Phoenix.Naming.humanize(&1)})]
  end

  # A row names itself, and carries the record its job is writing — built once
  # for the table rather than looked up per cell.
  defp rows(jobs, work),
    do: Enum.map(jobs, &%{dom_id: "job-#{&1.id}", job: &1, work: work[&1.id]})

  # The worker's own name, without the application prefix: the queue is "sync",
  # and which module runs there is the last segment.
  defp worker_name(worker) do
    worker |> String.split(".") |> List.last()
  end

  defp trigger(%{args: %{"trigger" => trigger}}) when is_binary(trigger), do: trigger
  defp trigger(_job), do: nil

  # What the job acts on. A worker that can say it better passes a `scope`
  # argument and it is printed as written ("every space", "the whole site, what
  # changed"); otherwise the page reads the arguments back to the reader, which
  # is why it knows no worker by name — a job added tomorrow says its own scope
  # without a change here. The only thing spelled out is how an argument names
  # itself: `space_key` reads as "space", the rest keep their key. `trigger` is
  # left out because who asked is a column of its own.
  @argument_names %{"space_key" => "space", "confluence_id" => "page"}

  defp scope(%{args: %{"scope" => scope}}) when is_binary(scope), do: scope

  defp scope(%{args: args}) do
    case args |> Map.delete("trigger") |> Enum.map_join(", ", &name_argument/1) do
      "" -> nil
      text -> text
    end
  end

  defp name_argument({key, value}) do
    "#{Map.get(@argument_names, key, key)} #{answer(value)}"
  end

  defp answer(value) when is_binary(value), do: value
  defp answer(value), do: inspect(value)

  # "Long-running" is said only about a job that has been executing longer than
  # any run this mirror has measured; a shorter one is simply working.
  defp overdue?(%{state: "executing", attempted_at: %DateTime{} = at}, now) do
    DateTime.diff(now, at, :minute) >= @longest_run_minutes
  end

  defp overdue?(_job, _now), do: false

  # The tone a record's own status carries; the page knows these five and nothing
  # about which statuses exist, which is what lets a new record use it as is.
  # The tone a record gives its own words. The state is a column of its own, so
  # this cell borrows only the colour.
  defp tone_text(:ok), do: "text-success"
  defp tone_text(:warn), do: "text-warning"
  defp tone_text(:error), do: "text-error"
  defp tone_text(_tone), do: ""

  defp state_class("executing"), do: "badge-warning"
  defp state_class("available"), do: "badge-info"
  defp state_class("scheduled"), do: "badge-ghost"
  defp state_class("retryable"), do: "badge-warning"
  defp state_class("completed"), do: "badge-success"
  defp state_class("cancelled"), do: "badge-ghost"
  defp state_class("discarded"), do: "badge-error"
  defp state_class(_other), do: "badge-ghost"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      live={@socket}
      spaces={@spaces}
      last_sync_run={@last_sync_run}
      mirror_name={@mirror_name}
      mirror_url={@mirror_url}
      mirror_host={@mirror_host}
      mirror_source={@mirror_source}
      page_title="Jobs"
      sidebar?={false}
    >
      <.admin_header
        current={:jobs}
        title="Jobs"
        subtitle="What Oban holds, in every state — the overview's queue lists only what is still waiting to start."
      />

      <div class="mt-4 flex flex-wrap items-center gap-3">
        <form id="jobs-filter" phx-change="filter">
          <select
            id="jobs-state"
            name="state"
            class="select select-sm rounded-lg border-base-300"
            aria-label="State"
          >
            <option
              :for={{value, label} <- @state_options}
              value={value}
              selected={value == @state}
            >
              {label}
            </option>
          </select>
        </form>

        <p id="jobs-open" class="text-[11px] text-base-content/70">
          {open_sentence(@unfinished)}
        </p>
      </div>

      <.section title="Oban's own rows" class="mt-4">
        <.data_table id="jobs" rows={@rows}>
          <:head>
            <th>#</th>
            <th title="The worker that runs it, and who asked for it">Job</th>
            <th title="What this job acts on, as its own arguments name it">Scope</th>
            <th>State</th>
            <th title="Attempts made out of the attempts allowed">Tries</th>
            <th title="When the job was queued">Queued</th>
            <th>Last attempt, or when it is due</th>
            <th title="Whatever the job's own record says: a line of progress, why it ended, and a link to its log. The one column a job fills in for itself.">
              Details
            </th>
            <th><span class="sr-only">Stop</span></th>
          </:head>
          <:row :let={row}>
            <% job = row.job %>
            <td class="text-xs tabular-nums text-base-content/70">{job.id}</td>
            <td class="text-xs">
              <span class="font-medium">{worker_name(job.worker)}</span>
              <span
                :if={trigger(job)}
                id={"job-#{job.id}-trigger"}
                class="block text-[11px] text-base-content/70"
              >
                {trigger(job)}
              </span>
            </td>
            <td class="text-xs" id={"job-#{job.id}-scope"}>
              <%= if scope(job) do %>
                {scope(job)}
              <% else %>
                <span
                  class="text-base-content/70"
                  title="This job takes no arguments: it acts on everything its worker knows how to find."
                >
                  —
                </span>
              <% end %>
            </td>
            <td>
              <span class={["badge badge-sm", state_class(job.state)]}>{job.state}</span>
            </td>
            <td class="text-xs tabular-nums">{job.attempt}/{job.max_attempts}</td>
            <td class="whitespace-nowrap text-xs">
              <.local_time at={job.inserted_at}>{Time.ago(job.inserted_at)}</.local_time>
            </td>
            <td class="whitespace-nowrap text-xs">
              <%= if job.state == "executing" do %>
                <.local_time at={job.attempted_at}>{Time.ago(job.attempted_at)}</.local_time>
                <%!-- A job that is merely slow and a job whose node is gone look
                identical in Oban: nothing writes to an executing row until it
                ends. Saying how long is the most this page can honestly do. --%>
                <span
                  :if={overdue?(job, @now)}
                  class="badge badge-outline badge-xs ml-1"
                  title={
                    "Executing for longer than any run this mirror has measured " <>
                      "(~2 hours). If no sync is running, this is a leftover from a restart."
                  }
                >
                  long-running
                </span>
              <% else %>
                <.local_time at={job.scheduled_at}>{Time.ago(job.scheduled_at)}</.local_time>
              <% end %>
            </td>
            <%!-- The one column a job fills in for itself. `Jobs.Progress` is a
            protocol over the record a worker writes, so a kind of job that
            arrives later brings its own words and its own log link and this
            page does not change. --%>
            <td class="text-xs" id={"job-#{job.id}-details"}>
              <%= if row.work do %>
                <% {_state, tone} = Progress.state(row.work) %>
                <span class={["block", tone_text(tone)]}>{Progress.summary(row.work)}</span>
                <span
                  :if={Progress.detail(row.work)}
                  class="block text-[11px] text-base-content/70"
                >
                  {Progress.detail(row.work)}
                </span>
                <%= if log = Progress.log(row.work) do %>
                  <.link
                    navigate={elem(log, 1)}
                    class="link link-hover text-primary"
                    title={"Open the #{elem(log, 0)} of this job's work"}
                  >
                    {elem(log, 0)}
                  </.link>
                <% end %>
              <% else %>
                <span
                  class="text-base-content/70"
                  title="This job's own record says nothing yet. A job that has not started has none, and a job queued before the mirror recorded job ids cannot point at its work."
                >
                  —
                </span>
              <% end %>
            </td>
            <td class="text-right">
              <button
                :if={job.state in Jobs.unfinished_states()}
                type="button"
                id={"stop-job-#{job.id}"}
                phx-click="cancel"
                phx-value-id={job.id}
                phx-disable-with="Stopping…"
                data-confirm={
                  "Cancel job ##{job.id} (#{worker_name(job.worker)}, #{job.state})?\n\n" <>
                    "It will not run again. A running job is stopped where it is; whatever it " <>
                    "already wrote stays."
                }
                title="Cancel this job: it will not run again"
                class="btn btn-warning btn-outline btn-xs gap-1"
              >
                <.icon name="hero-stop" class="size-4" /> Stop
              </button>
            </td>
          </:row>
          <:empty>No jobs in this state.</:empty>
        </.data_table>
      </.section>
    </Layouts.app>
    """
  end

  defp open_sentence(0), do: "Nothing is waiting or running."
  defp open_sentence(1), do: "1 job has not finished."
  defp open_sentence(count), do: "#{count} jobs have not finished."
end
