# The mirror's state machines

Every long-lived thing in this application is a small state machine. A few are
explicit — a `status` column with a list of allowed values — and most are
implicit: a set of nullable timestamps, a boolean that another boolean overrides,
a row that exists while a file exists. Implicit machines are not worse; they are
just undocumented, and an undocumented machine has no invariants that anyone can
check, so the code drifts and the drift is only found by an operator.

This file writes them down: the states, the invariants that must hold in every
state, the transitions that are allowed, and — separately — the invalid states
and transitions that the code can actually reach today, with the evidence. It is
a description of `HEAD`, not a design wish: when a machine changes, this file
changes in the same commit.

**How to read the tables.** `state` is what a row holds, not what a user sees.
`who` names the code that performs the transition. Rows marked ⚠ are reachable
transitions this document records as defects or accepted risks, with the reason
and the impact given below the table.

Defects 1 and 2 are fixed (issues
[#12](https://github.com/d-led/confluence_phx_mirror/issues/12),
[#13](https://github.com/d-led/confluence_phx_mirror/issues/13)); defects 3–6 and
the accepted risks are tracked in
[#14](https://github.com/d-led/confluence_phx_mirror/issues/14).

The machines:

| # | Machine | Storage | Kind | Owner |
|---|---------|---------|------|-------|
| S1 | Sync run | `sync_runs.status`, `cancel_requested_at`, `job_id` | explicit | `Sync`, `Sync.SyncRun` |
| S2 | Sync gate lease | `sync_gate.owner`, `expires_at` | implicit (lease) | `Sync.Gate` |
| S3 | Sync job | Oban `jobs.state` + worker return values | explicit | `Sync.*Worker`, `Jobs` |
| S4 | Verify pass | `reconcile_runs.finished_at` | implicit (NULL = open) | `Sync.ReconcileRun` |
| S5 | Page | `pages.status`, `deleted_at`, `deleted_reason`, `absent_since` | mixed | `Mirror`, `Sync`, `Trash`, `Webhooks` |
| S6 | Page freshness | `pages.render_revision`, `details_synced_at`, `synced_at` | implicit (comparisons) | `Sync`, `Mirror` |
| S7 | Space | `spaces.deleted_at`, `pages_listed_at` | implicit | `Mirror`, `Sync` |
| S8 | Space scope | `sync.spaces` setting + `CM_SPACES` | implicit (`[]` ≡ `:all`) | `Sync.SpaceScope` |
| S9 | Webhook delivery | `webhook_deliveries.status` | explicit, unvalidated | `Webhooks` |
| S10 | Mail ledger + notification | `mail_sends.state`, `notifications.delivered_at`/`error` | explicit + implicit | `Mail.Budget`, `Mailer`, `Notifications` |
| S11 | Account | `role` + four nullable timestamps | implicit | `Accounts` |
| S12 | Prepared export | ETS entry + file on disk | implicit | `Export.Artifact` |
| S13 | Published settings | `settings` rows + `:persistent_term` | implicit (cache) | `Settings` |

---

## S1 — Sync run

One row per attempt to bring part of the mirror up to date. The row is the audit
record *and* the cancellation channel, which is why it has two writers: the
process doing the work, and whoever presses Cancel.

**States**

| state | meaning |
|-------|---------|
| `running` | the row exists and a process is (supposed to be) working on it |
| `succeeded` | finished, no per-scope errors |
| `partial` | finished, but `stats["errors"]` is non-empty |
| `failed` | ended badly; `error` says how |
| `cancelled` | somebody asked it to stop and it did |

`finished_at` is set exactly in the four terminal states and `nil` in `running`,
except during the first instant of a resumed row (`resume_run/1` clears it).

**Invariants**

1. A `running` row has a holder of the gate, or is about to be swept
   (`Sync.abandon_abandoned_runs/0`) — see S2.
2. `finished_at != nil` ⟺ `status != "running"`.
3. `mode ∈ {snapshot, incremental, webhook, page, space, people}`
   (`SyncRun.@modes`, validated in `changeset/2`).
4. `status ∈ {running, succeeded, partial, failed, cancelled}`
   (`SyncRun.@statuses`, validated).
5. A run that raised is recorded `failed` **and** the raise travels on, so Oban
   retries (`sync.ex` `run_locked/4` rescue/catch). A run that was cancelled
   returns normally, so Oban does **not** retry it.
6. `cancel_requested_at` is write-once and never cleared.

**Transitions**

| from | to | who | how |
|------|----|-----|-----|
| — | `running` | `Sync.start_run/5` | insert |
| `failed` | `running` | `Sync.resume_run/1` | a retried Oban job continues its own run (`resumable_run/1` matches `job_id` + `status == "failed"`) |
| `running` | `succeeded` / `partial` | `Sync.finish_run/5` | work returned without raising |
| `running` | `failed` | `Sync.fail_run/4` | raise / catch |
| `running` | `cancelled` | `Sync.finish_cancelled/3` | `Cancelled` rescued in `run_locked/4` |
| `running` | `failed` | `Sync.abandon_run/1` | the gate is free ⇒ the owner is gone |

**Reachable invalid states**

- ⚠ **`failed → running` keeps `cancel_requested_at`** (`sync.ex:2698`
  `resume_run/1` resets `status`, `finished_at`, `error` — not
  `cancel_requested_at`). A run that somebody cancelled but that *failed* first
  therefore cancels itself at the first page of its retry. Observed behaviour is
  acceptable (the operator asked for a stop), but the state reads as
  "cancelled without a cancel" in the audit trail. Documented, not fixed.
- ⚠ **A killed process is recorded as a cancellation.** `run_work/4` maps
  `:shutdown`, `:killed` **and** `:normal` DOWN reasons to `Cancelled`
  (`sync.ex:355-371`), and `finish_cancelled/3` writes `error: "stopped on
  request; the N pages listed before that stay"`. `Runs.stop/1` sends
  `:shutdown`, so `:killed` is an OOM kill / brutal supervisor shutdown, and
  `:normal` is a child that exited without reporting. Both are recorded as a
  deliberate operator action. Impact: the audit trail says a person asked when
  nobody did, and `SyncRun` reports `:idle` tone for it
  (`jobs/progress/sync_run.ex:49`). Documented; changing it changes what
  operators are told, so it needs a decision, not a patch.
- ⚠ **`succeeded` can overwrite `failed`.** `abandon_abandoned_runs/0` marks a
  `running` row failed when the gate is free; a run whose lease lapsed (S2) is
  alive and keeps going, then `finish_run/5` writes `succeeded`. Two audit
  entries, contradictory, for one run. Requires a lapsed lease — see S2.

---

## S2 — Sync gate lease

`sync_gate` is a single row claimed by whoever starts a run and renewed by a
heartbeat for as long as the claiming process lives. It replaces a Postgres
advisory lock on purpose (`gate.ex` moduledoc: a session lock belongs to a
connection, and a mirror has a pool, two Machines and deploys).

**States**

| state | meaning | representation |
|-------|---------|----------------|
| free | nobody is running | `owner IS NULL OR expires_at IS NULL OR expires_at < now()` |
| held | one run is alive | `owner = <uuid> AND expires_at > now()` |

**Invariants**

1. At most one run writes the mirror at a time.
2. A held lease is renewed every `lease_seconds/3` (90 s ÷ 3 = 30 s) by a process
   that stops renewing exactly when its claimant dies (`keep_alive/1` monitors the
   claimant, so a `:DOWN` ends the heartbeat).
3. `release/1` only clears a row whose `owner` matches — a run that lost its lease
   cannot release the new holder's claim.
4. `Sync.run/2` sweeps abandoned rows **before** claiming (`sync.ex:123`), so the
   sweep can never be confused by its own run.

**Transitions**

| from | to | who |
|------|----|-----|
| free | held | `Gate.claim/1` (one atomic upsert) |
| held | held (renewed) | `Gate.renew/1`, every heartbeat |
| held | free | `Gate.release/1` in `exclusive/1`'s `after` |
| held | free | the lease expiring, when the claimant dies |

**Reachable invalid states**

- ⚠ **A lapsed lease is not a stopped run.** `beat/2` calls `renew/1`, which is
  `Repo.update_all/2`; if it raises (a database error, a pool checkout timeout)
  the heartbeat `Task` — started with `Task.start/1`, so unlinked and
  unsupervised — dies silently. The run continues writing while the gate lapses
  90 s later, and the next `Sync.run/2` claims it. Two runs then write the same
  pages concurrently. Impact: wasted work, plausible `40P01` deadlocks between
  two runs' upserts, and `abandon_abandoned_runs/0` recording the *first* run as
  failed while it is still alive (S1). Not fixed here: the fix is a supervision
  decision (supervise the heartbeat and stop the run when it dies), not a patch.

---

## S3 — Sync job (Oban)

The domain row of S1 hangs off a job. Neither alone says what is happening, which
is why `Jobs` only ever states what Oban's rows say and asks the *record* for the
rest (`Jobs.Progress`).

**States** (`Jobs.states/0`): `executing`, `available`, `scheduled`,
`retryable` (unfinished) → `completed`, `cancelled`, `discarded` (settled).

**Invariants**

1. `executing` job ⇒ a process exists — **except** after a deploy, which is why
   `Jobs.unfinished?/1` says "Oban holds a job", never "something is running".
2. A worker that is not finished returns `:ok`, `{:snooze, seconds}` or
   `{:cancel, reason}`; a worker that failed raises and lets Oban retry.
3. Only `@synchronised_workers` (`sync.ex:566`) may be judged by the gate: they
   take it, so a free gate proves their process is gone. `SweepWorker` and
   `TrashAbsentWorker` share the queue and do **not** take it, so they are
   exempt — reading their silence as death once cancelled every sweep a minute
   after it started.
4. A snooze does not spend an attempt (`Sync.paused_wait/0`), so an hour of pause
   cannot discard a job.

**Transitions that matter**

| from | to | who | why |
|------|----|-----|-----|
| `executing` | `scheduled` | `{:snooze, n}` | paused mirror, or `wait_or_stand_down/0` |
| `executing` | `cancelled` | `{:cancel, reason}` | a whole-site run is reading that space anyway; desktop tool with no spaces chosen |
| `executing` | `retryable` | raise | `Sync` recorded the run as failed |
| `executing` | `completed` | `:ok` | includes `{:error, :already_running}` for `SnapshotWorker` — the tick is dropped by design |

**Reachable invalid states**

- ⚠ **An `executing` job outlives its node.** Covered by
  `Sync.release_orphaned_jobs/0` for the five synchronised workers only, with a
  60 s grace (`@gate_grace_seconds`). A non-synchronised worker that dies stays
  `executing` until Oban's `lifeline` (6 h). Accepted: those workers raise their
  own failures, and `max_attempts: 1` makes a `discarded` row visible.

---

## S4 — Verify pass

`reconcile_runs` has one implicit state and one only: `finished_at IS NULL` means
"open". It is deliberately *not* a claim that anything is running — resume
depends on it, so it must survive a killed process.

**States**

| state | representation |
|-------|----------------|
| open (resumable) | `finished_at IS NULL AND started_at >= now() - 24h` |
| open (stale) | `finished_at IS NULL AND started_at < now() - 24h` |
| finished | `finished_at IS NOT NULL` |

**Invariants**

1. An observation row is a *promise*: the space was asked. `observe/3` inserts
   with `on_conflict: :nothing`, and `observed_space_ids/1` is what a resumed
   attempt skips, so a space is never asked twice in one pass.
2. Only one pass may be in flight (`ReconcileWorker` uniqueness + the gate).
3. "Is a pass running?" is **not** answerable from this table — a page must ask
   `Jobs.unfinished?(ReconcileWorker)` too (documented in `unfinished/0`).

**Transitions**: `— → open` (`resume_or_start/1`), `open → finished`
(`finish/2`), `open(stale) → (abandoned, a new pass starts)`.

**Reachable invalid states**

- ⚠ **A stale-open pass looks identical to a killed one.** After a deploy kills a
  pass, the row stays open until the resume window ends (24 h). `unfinished/0`
  reports it as a cursor and the screen must cross-check Oban — a caller that
  forgets says "a check is running" for a day. Accepted (documented in the
  module), but a second caller is one bug away.

---

## S5 — Page

Five fields, one lifecycle. This is the most implicit machine in the mirror and
the one an operator sees most of.

**States**

| state | `deleted_at` | `deleted_reason` | `absent_since` |
|-------|--------------|------------------|----------------|
| live | NULL | NULL | NULL |
| absent | NULL | NULL | set |
| trashed, the mirror's inference | set | `"vanished"` | NULL |
| trashed, a person's decision | set | `"manual"` | NULL |
| purged | row gone | | |

`pages.status` (`current` / `draft` / `archived`) is orthogonal: it is what the
*site* says the page is, never a lifecycle state. `archived` pages are mirrored
and served, and excluded from listings.

**Invariants**

1. `absent_since != nil` ⇒ `deleted_at == nil`. An absence is a verdict from a
   listing *about a page we hold*; a trashed page is not a candidate
   (`mark_absent/2` filters `is_nil(deleted_at)`; `absent_pages/1`,
   `count_absent/0` filter it too).
2. `deleted_at != nil` ⇒ `deleted_reason ∈ {"vanished", "manual"}`.
3. `"manual"` outranks `"vanished"`: a sync never lifts a person's decision
   (`lift_vanishing/1`, `mirror.ex:2235`), and `change_of/4` treats a
   manual-trashed page as **current** so that a snapshot does not rewrite it on
   every run (`sync.ex:2008-2010`, "rewriting it every run would say it had").
4. `"vanished"` is lifted by the next write of that page: Confluence does not bump
   a version when it restores a page from its own trash, so the renderer would
   otherwise leave it dead for good.
5. A listing that leaves a page out only sets `absent_since`; nothing is trashed
   without a person (`Trash`).

**Transitions**

| from | to | who | how |
|------|----|-----|-----|
| — | live | `Sync.upsert_page_record/4` | insert |
| live | absent | `Mirror.mark_absent/2` | listing did not name it |
| absent | live | `Mirror.mark_absent/2` | listing named it again (`absent_since: nil`) |
| absent | live | `Mirror.upsert_page/2` | any write revives (`revive_page/1`) |
| absent | trashed `vanished` | `Trash.trash_page/3`, `Mirror.trash_all_absent/0` | a person clears the review list |
| live | trashed `vanished` | `Webhooks.mark_deleted/3` | a removal webhook |
| live/absent | trashed `manual` | `Mirror.mark_deleted/2` (default reason), `Mirror.trash_space/2` | an operator removes a page/space |
| trashed `vanished` | live | `Mirror.upsert_page/2` | the site lists it again |
| trashed | purged | `Trash.purge_page/2`, `purge_due/2` | rows and blobs deleted |

**Reachable invalid states**

- ⚠ **`deleted_at` and `absent_since` can both be set** — violating invariant 1.
  `Mirror.mark_deleted/2` (`mirror.ex:1997`) writes `deleted_at` and
  `deleted_reason` only, while every other trash path also clears `absent_since`
  (`trash_pages/3`, `trash_absent/1`). Reachable in two ways, both ordinary:
  `Trash.trash_page/3` (`trash.ex:174`) trashes a page *from the absent list*, so
  it is absent by construction; and a removal webhook for a page a verify pass
  flagged. Consequence: `change_of/4`'s `not previous.current?` then forces a full
  re-read/rewrite of that page on the next snapshot — exactly the "rewriting it
  every run" the code comment forbids — and, with reason `"vanished"`, the
  rewrite lifts the trash, so the page the operator just trashed comes back one
  run later. **Fixed** (see Defect 2).
- ⚠ **A webhook can overwrite a `"manual"` trash** — violating invariant 3.
  `Mirror.mark_deleted/2` changes `deleted_reason` unconditionally, so a
  `page_removed` delivery for a page an administrator trashed rewrites it to
  `"vanished"`, and the next sync that lists the page lifts the trash. The
  administrator's decision is silently converted into a vanishing. **Fixed**
  (see Defect 2).

---

## S6 — Page freshness (render + details)

Two comparisons, not two flags, decide whether a stored page is up to date.

**States, per page**

| | condition |
|---|---|
| unrendered | `body_export IS NULL` ⇒ `change_of/4` re-reads regardless of version |
| behind the renderer | `render_revision != Sync.Renderer.revision()` ⇒ re-rendered |
| details stale | `details_synced_at IS NULL` ⇒ the details backlog re-reads comments/files/restrictions |
| live-doc fresh | `subtype == "live"` and `now - synced_at < sync.live_doc_refresh_seconds` ⇒ left alone unless forced |

**Invariants**

1. A version change stores the new body **and** clears `details_synced_at` in
   one transaction (`upsert_page_record/4`), so an interrupted detail pass is
   simply a page the backlog reads again — never a page claiming details it does
   not have.
2. A renderer fix reaches old pages only through `render_revision`
   (`Renderer.revision/0`); a page keeps its old links until it is re-synced.
3. Only a live doc is rate-limited; `force: true` (an administrator's resync) is
   the only way past the floor.

**Reachable invalid states**: none found. The state is derived from stored
values, and every write that could make it lie is in the transaction it belongs
to.

---

## S7 — Space

**States**

| state | `deleted_at` | `pages_listed_at` |
|-------|--------------|-------------------|
| discovered but never listed | NULL | NULL |
| listed | NULL | set |
| trashed | set | (kept) |
| purged (with its pages) | row gone | |

**Invariants**

1. `pages_listed_at IS NULL` means "the run that sees this row must list it
   properly" (`ensure_space/3` makes rows from one changed page). Marking happens
   only after the whole listing landed, so an interruption resumes.
2. A listing that stops naming a space is **reported**, never acted on
   (`Mirror.spaces_not_listed/1`): a token that lost access and a deleted space
   look identical.
3. Only a person trashes a space (`Trash.forget/2`, `Mirror.prune_missing_spaces/1`)
   and the pages go with reason `"manual"`.

**Reachable invalid states**: none found. `trash_space/2` revives on the next
write of the space (`revive_space/1`), which is the same rule as S5.

---

## S8 — Space scope

A one-field machine with an overloaded value: `:all` **and** `[]` both mean
"mirror everything".

**States**: `:all` (deployment names nothing and the runtime list is empty) ·
whitelist (a list of normalised keys) · widened whitelist (`CM_SPACES` ∪
`sync.spaces`).

**Invariants**

1. Neither list names anything ⇒ `:all`.
2. Once the deployment names spaces, the runtime list can only widen it. Removing
   a key at runtime would narrow the mirror by accident and the environment would
   restore it at the next boot anyway.
3. On the desktop tool, an `:all` run is **refused** (`SnapshotWorker.scoped?/0`):
   a tool never mirrors the whole site by itself.

**Reachable invalid transitions**

- ⚠ **Removing the last runtime key widens the mirror to the whole site.** On a
  mirror whose deployment sets no `CM_SPACES` (the demo, a server given one
  site), `sync.spaces == []` means `:all`, so deleting the last entry on
  `/admin/settings` switches a narrowed mirror back to everything — the opposite
  of what the operator just did. Only the desktop tool refuses that run; a server
  starts copying the whole site. Deliberate (`wanted/0` cannot express "nothing"),
  documented here because the direction of the surprise is a support ticket.

---

## S9 — Webhook delivery

**States** (`Webhooks`): `received`, `processing` (written at insert),
`queued`, `processed`, `ignored`, `rejected`, `failed`.

**Intended shape**: `--- → received|processing → (one terminal state)`.

**Invariants**

1. Every delivery is stored before anything else happens, valid or not
   (`store_delivery/3`), because a rejected payload must be inspectable.
2. Exactly one terminal state per delivery, written by `finish/3`.
3. A switched-off intake stores nothing (`receive/4` returns `{:error, :disabled}`
   before `accept/4`) and the route answers as if it did not exist.

**Reachable invalid states**

- ⚠ **Non-terminal states are reachable as resting states.** The initial status
  is a function of the *configuration*, not of what happened
  (`webhooks.ex:305`: `if(secret, do: "processing", else: "received")`), and only
  `finish/3` moves it on. If handling raises between the insert and the finish —
  a `40P01` deadlock inside `Mirror.mark_deleted/2`, an `Audit.log/2` insert
  error, a `Repo.update!` failure — the row stays `processing` for the lifetime
  of the deployment, and `/admin/webhooks` prints the word (`webhooks_live.ex:403`)
  with nothing sweeping it. There is no replay mechanism, so the row is the only
  record of a delivery that was received and not handled. Impact: an operator
  cannot tell "handled" from "died mid-flight". Documented; the fix is a sweep
  (the same pattern as `abandon_abandoned_runs/0`) rather than a `try`.
- ⚠ **`status` is not validated.** `Delivery.changeset/2` casts it and validates
  only `[:payload, :received_at]`, so any string is storable and the seven words
  above are a convention. Low impact today (one writer), but the invariant is
  unenforced.

---

## S10 — Mail: the ledger and the notification row

Two records of one message, written by two modules.

**`mail_sends.state`**: `pending` (the slot is reserved, the message not yet
handed over) → `sent` (the relay took it) | `failed` (it did not go; the key is
freed, the day's slot is not).

**`notifications`**: `delivered_at IS NULL AND error IS NULL` = waiting;
`delivered_at` set = told; `error` set with `delivered_at` still NULL = the last
attempt failed and a retry may still happen.

**Invariants**

1. `pending` and `sent` rows hold their `dedup_key`: a retried job cannot send
   the same message twice (`Budget.reserve/1`, partial unique index
   `WHERE state <> 'failed'`). `failed` frees the key, because the message never
   went.
2. The day is UTC and counts refusals: `used/0` counts every row of today,
   `remaining/0` is `max(limit - used, 0)`.
3. The ledger is written **before** the relay is called, so the guarantee is
   one-directional by design: a crash can lose a message, never duplicate one.
4. `{:error, :already_sent}` on a retry marks the notification delivered — the
   ledger is the truth, the notification row follows (`email_worker.ex:88-90`).

**Reachable invalid states**

- ⚠ **A `pending` row has no expiry.** A crash between `claim/1` and
  `mark_sent/1`/`mark_failed/1` leaves `pending` for ever: its key can never be
  reused (so a `welcome:` or `test:` message is lost permanently, not just for
  that day) and the row counts against that day's allowance. Accepted trade-off
  (documented in `Mail.Budget`), recorded here because "lose one message"
  understates it: it is a *permanent* loss for any key that is not day-scoped.
- ⚠ **The two records can disagree.** `mark_sent/1` and `mark_delivered/1` are
  separate statements. A process killed between them leaves a `sent` ledger row
  and an undelivered notification; the retry then takes `{:error, :already_sent}`
  and marks it delivered, so the disagreement heals on the next attempt — but
  only if one happens.

---

## S11 — Account

Four nullable timestamps and a role. The access question is derived, never
stored.

**States** (derived)

| state | condition | may sign in |
|-------|-----------|-------------|
| active | no flags | yes |
| switched off here | `disabled_at` | no |
| switched off on the site | `site_disabled_at` | no, unless `MIRROR_ALLOW_SITE_DISABLED_READERS` |
| gone from the site | `site_deleted_at` | no |
| banned | `banned_at` | no |
| provisioned | `provisioned_at` set | — (orthogonal: says *who* made the row) |

**Invariants**

1. `User.disabled?/1` is the single access answer every door uses
   (`user.ex:126`); the flags stay independent so a screen can say "we did this"
   from "the site did this".
2. A ban outranks everything and blocks deletion, because deleting would let the
   next sign-in provision a fresh account.
3. The mirror must keep one administrator: `last_admin?/1` is asked by
   `set_disabled/3`, `change_role/3`, `ban/2` and `delete_user/2`.
4. "Another administrator" means an account that is **a way in**: a seeded
   address that can still sign in, another enabled account with the role, or a
   member of an admin group.
5. `site_deleted_at` outranks `site_disabled_at` (`site_flags/1`), because a
   deleted account is not a deactivated one.

**Reachable invalid states**

- ⚠ **A site-deleted administrator counts as "another way in"** — violating
  invariant 4. `Accounts.enabled_accounts/0` (`accounts.ex:511`) filters
  `disabled_at`, `site_disabled_at` and `banned_at` but **not**
  `site_deleted_at`, while `User.disabled?/1` treats `site_deleted_at` as
  blocking (`site_blocks_use?/1`). So with two admins where the site deleted one,
  `last_admin?/1` is false for the other, and switching it off, demoting it,
  banning it or deleting it all succeed: **the mirror is locked out of
  administration** with no sync and no sign-in able to undo it (a ban especially).
  The two sibling checks — `seed_can_sign_in?/1` and `member_can_sign_in?/1` — use
  `User.disabled?/1` and are right; this one is the odd one out. **Fixed** (see
  Defect 1).

---

## S12 — Prepared export artifact

`Export.Artifact` is a GenServer over one ETS entry per archive name plus one file
on disk. One build at a time, whoever asks first.

**States**

| state | representation |
|-------|----------------|
| absent | no ETS entry, or the entry is `:absent` |
| building | `{:building, %{by, since, bytes, pid}}` |
| ready | `{:ready, %{bytes, at, by, version}}` |
| discarded | swept after 6 h, or on boot |

**Invariants**

1. A build is one process; `prepare/2` answers `{:busy, by}` while one runs.
2. "Ready" is only valid while the content version it was built from is
   unchanged (`Export.site_archive_version/0`); a mismatch is a rebuild.
3. A build is dead when its **process** is, not when a clock says so
   (`discarded?/2`), and only after `stale_build_ms` (1 h) as a floor.
4. The folder is emptied at boot: a half-written archive answers a download with
   a zip that stops halfway.

**Reachable invalid states**

- ⚠ **A build that dies stays `building` for up to an hour.** `discarded?/2`
  requires `since >= stale_build_ms` **and** a dead pid, so a build whose process
  was killed one second ago blocks `prepare/2` with `{:busy, by}` until the floor
  passes. The builder itself rescues and reports `{:failed, …}`, so this needs a
  kill the task cannot observe. Accepted (self-healing, ≤ 1 h, no data loss).
- ⚠ **`{:building, pid: nil}` exists between `start/3` and the task's first
  write.** `alive?(nil)` is false, so such an entry is swept as soon as the floor
  passes. Harmless; noted because it is a state with no process by construction.

---

## S13 — Published settings

Two copies of one fact: the `settings` rows (truth) and `:persistent_term`
(cache, read on every request).

**Invariants**

1. A write is one transaction — rows *and* the audit entry — and the cache is
   refreshed only after the commit returns (`settings.ex` moduledoc).
2. A failed save leaves the table and the running site exactly as they were.
3. Reads never touch the database; `load/0` fills the cache at boot.
4. A key with no stored value falls back to the deployment's configuration — one
   default, in one place (`Settings.Catalogue`).

**Reachable invalid states**: the cache can be stale relative to the table only
if a process dies between the commit and the cache refresh, which leaves the
*previous* values in force until the next write or boot. No review, no lost
write. `Settings.forget` is the repair, and test suites must call it because a
rolled-back sandbox transaction does not roll back `:persistent_term`.

---

## Concurrency and retries: the cross-machine rules

These are the places where two machines meet, which is where state machines in
this codebase actually break.

1. **One run at a time** is enforced by S2, not by Oban's uniqueness: uniques are
   per queue and per node, and a mirror is a pool and two Machines.
2. **`Sync.run/2` sweeps before it claims** (`sync.ex:123`). If it swept after
   claiming, it would read its own run's silence as death — which is why
   `abandon_abandoned_runs/0` must stay *outside* `Gate.exclusive/1`.
3. **A retried job continues its own run** (S1 `failed → running`), so one press
   is one row and one log, not three.
4. **Cancellation has two channels**: killing the local child (`Runs.stop/1`) and
   `cancel_requested_at`, which is the only signal a run on another node or a
   `mix` process can see. The kill is tried first so the work stops now.
5. **The kill and the result race**: if the child sent its result just before it
   was killed, the run is recorded by whichever message the parent receives
   first — `succeeded`/`partial` if the result won. The operator's `cancel/2` then
   answers `{:ok, run}` for a run that succeeded (`sync.ex:413-437`, the
   `stopped == :stopped` branch). Harmless, and the honest outcome of a genuine
   race.
6. **Two sweeps may run at once.** `abandon_abandoned_runs/0` is called from
   `Sync.run/2` and from the sweep; with the gate free, both may mark the same
   rows failed, producing two `sync_run.abandoned` audit entries for one run. No
   data is lost.
7. **Notifications retry on the ledger, not on the row** (S10 invariant 4): the
   dedup key is the idempotency token, so a retry after a crash cannot duplicate
   a message — only lose one.

---

## Confirmed defects, by impact

### Defect 1 — A site-deleted administrator still counts as a way in (S11)

*Issue #12, fixed.*

- **Impact: high.** The last administrator can be switched off, demoted, banned
  or deleted, leaving a mirror nobody can administer. A ban is unrecoverable by
  sign-in or sync; unbanning needs an administrator.
- **Evidence:** `accounts.ex:476` `other_role_admin?/1` → `enabled_accounts/0`
  (`accounts.ex:511`) filters `disabled_at`, `site_disabled_at`, `banned_at` and
  not `site_deleted_at`; `user.ex:126-133` `disabled?/1` → `site_blocks_use?/1`
  treats `site_deleted_at` as blocking. `last_admin?/1` therefore answers false.
- **Reachable:** two administrators, one of whom the site deleted
  (`Accounts.reconcile_site_status(id, email, :deleted)`), which is the ordinary
  outcome of somebody leaving.
- **Fix:** one SQL clause, plus the two regression cases the existing
  "an administrator who is switched off is not a way in" test was missing.
- **Grouped with:** nothing. Ship alone.

### Defect 2 — `mark_deleted/2` breaks two page invariants (S5)

*Issue #13, fixed.*

- **Impact: medium.** (a) A trashed page can keep `absent_since`, which makes
  `change_of/4` re-read and rewrite it on the next snapshot, and — with reason
  `"vanished"` — lets the page come back out of the trash after an explicit
  decision. (b) A webhook can convert a `"manual"` trash into `"vanished"`, which
  a later sync lifts: an administrator's decision silently undone.
- **Evidence:** `mirror.ex:1997-2012` writes `deleted_at` and `deleted_reason`
  only; `trash_pages/3` (`mirror.ex:2247`) and `trash_absent/1`
  (`mirror.ex:1972-1985`) both also clear `absent_since`. `sync.ex:1920` and
  `sync.ex:2008-2010` are what read the difference. `trash.ex:174` passes
  `"vanished"` for a page that is absent by construction; `webhooks.ex:235`
  passes `"vanished"` for a page an operator may already have trashed.
- **Reachable:** the trash screen's own action, and any removal webhook for a
  manually trashed page.
- **Fix:** clear `absent_since` when trashing, and refuse to overwrite an existing
  `"manual"` reason.
- **Grouped with:** nothing.

### Defect 3 — A killed sync is recorded as a cancellation (S1)

*Issue #14, open.*

- **Impact: medium, but the fix is a decision, not a patch.** An OOM kill or a
  brutal supervisor shutdown writes `cancelled` with `error: "stopped on request"`,
  so nobody investigates the crash and the audit trail attributes it to a person.
- **Evidence:** `sync.ex:355-371`.
- **Not fixed here:** what operators are told is a product decision (a
  `"interrupted"` status, or `failed` with the exit reason). Recorded so the next
  person to read those three clauses knows they are a choice.

### Defect 4 — A lapsed gate lease does not stop the run (S2)

*Issue #14, open.*

- **Impact: medium.** Two runs can write the same pages concurrently, with
  deadlocks between their upserts and a contradictory pair of audit entries.
- **Evidence:** `gate.ex` `keep_alive/1` + `beat/2` + `renew/1`; `release/1`
  only matching its own owner; `Sync.abandon_abandoned_runs/0` closing a run that
  is still alive.
- **Not fixed here:** the fix is supervision (a heartbeat the claimant is linked
  to, so a dead heartbeat stops the run), which changes the process topology.

### Defect 5 — A webhook delivery can rest in `processing` (S9)

*Issue #14, open.*

- **Impact: low.** The record of a delivery that died mid-handling reads as
  "still going" for ever, and `/admin/webhooks` shows it.
- **Evidence:** `webhooks.ex:305`, `finish/3` at `webhooks.ex:311`,
  `webhooks_live.ex:403`.
- **Not fixed here:** needs a sweep, not a `try`; the delivery payload is the
  only record and must survive, so the row cannot be rolled back either.

### Defect 6 — Removing the last scoped space widens the mirror (S8)

*Issue #14, open.*

- **Impact: high when it happens, and it is a surprise.** A narrowed server
  mirror returns to copying the whole site.
- **Evidence:** `space_scope.ex:37-43` (`{:all, []} -> :all`), `configured/0`
  mapping `[]` to `:all`, `snapshot_worker.ex` refusing only on the desktop tool.
- **Not fixed here:** `[]` cannot be given the meaning "nothing" without changing
  what a deployment's configuration means. Documented; the screen should warn.

---

## Deliberate behaviour that reads like a bug

These are invariants the code *chooses*. Changing them needs the user, not a
refactor.

- **A sync never trashes what a listing stopped naming** (`absent_since` only).
  A token that lost access and a deleted page look identical from here.
- **`"manual"` outranks `"vanished"`** and no sync lifts it.
- **`{:error, :any}` on an `executing` snapshot is `:ok`** — the tick is dropped
  rather than queued behind a run that copies the same pages.
- **`already_running` for a `PageWorker` snoozes or stands down**, it never fails
  the job, so no event is lost and no attempt is spent.
- **`mail_sends` is written before the relay is called**, so the ledger can lose a
  message but never duplicate one.
- **The day boundary is UTC**, not the site's time zone.
- **`[]` and `:all` are the same space scope.**
