defmodule ConfluencePhxMirror.Fixtures do
  @moduledoc """
  Test helpers: demo syncs, users and subscriptions.
  """

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page, Space}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync

  @doc """
  One undelivered notification in the outbox.

  A fresh reader watches a page of its own, the page changes, and
  `ConfluencePhxMirror.Notifications` writes the row and queues its delivery —
  the road a real change takes, rather than a hand-built struct.

  The page is made here so two calls in one test cannot notify each other's
  subscriber: the outbox counts rows, and a shared page would quietly write two.
  """
  @spec queued_notification_fixture() :: ConfluencePhxMirror.Notifications.Notification.t()
  def queued_notification_fixture do
    page = space_fixture() |> page_fixture() |> Repo.preload(:space)
    subscriber = user_fixture()

    {:ok, _subscription} = Notifications.subscribe(subscriber, "page", page.id)

    [{:ok, notification}] = Notifications.page_changed(page, :updated)
    notification
  end

  @doc """
  Starts this test from an empty mirror.

  The suite mirrors the demo site once, before any test, and commits it — see
  `test/test_helper.exs` — so a test that wants the demo content pays for a
  read rather than for a thousand inserts. This is the other half of that
  bargain: a test whose subject is "a mirror with exactly what I built" says so,
  and gets its own blank one.

  The rows are deleted inside the test's transaction, so the committed copy is
  untouched and comes back when the test ends. `@tag :empty_mirror` (or
  `@moduletag`) asks `DataCase` to do this before the test body runs.

  A test that empties the mirror must not run beside another one: the deletes
  cascade into the same committed rows from both sides, and two of them meet on
  the foreign keys and deadlock (`40P01`). Tagged files are `async: false`.
  """
  @spec empty_mirror!() :: :ok
  def empty_mirror! do
    delete_everything(3)
  end

  # A deadlock is Postgres killing one of two transactions that reached the same
  # rows from opposite sides, so the answer is to try again — and the retry needs
  # a boundary of its own: a failed statement leaves the transaction unusable
  # until something rolls back to a savepoint. `Repo.transaction/1` is that
  # savepoint inside the sandbox's transaction, so a deadlocked attempt costs one
  # attempt and leaves the test's own transaction intact.
  defp delete_everything(attempts_left) do
    case Repo.transaction(fn -> delete_from_every_table() end) do
      {:ok, :ok} ->
        :ok

      {:error, error} when attempts_left > 1 ->
        if deadlock?(error), do: delete_everything(attempts_left - 1), else: raise(error)

      {:error, error} ->
        raise error
    end
  end

  defp delete_from_every_table do
    # Children first: the foreign keys point up at pages and spaces.
    for table <- ~w(
          page_properties page_labels page_restrictions links labels group_members
          comments attachments pages spaces
          sync_runs audit_events sync_gate
        ) do
      ConfluencePhxMirror.Repo.query!("DELETE FROM #{table}")
    end

    ConfluencePhxMirror.Mirror.Counters.clear()
    :ok
  end

  defp deadlock?(%Postgrex.Error{postgres: %{code: :deadlock_detected}}), do: true
  defp deadlock?(_other), do: false

  @doc "Mirrors the bundled demo snapshot and returns the finished sync run."
  def demo_snapshot! do
    {:ok, run} = Sync.run(:snapshot, gate: ConfluencePhxMirror.UnclaimedGate)
    run
  end

  @doc "A user with a deterministic e-mail."
  def user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email, "reader#{System.unique_integer([:positive])}@example.com")

    {:ok, user} = Accounts.ensure_user(email, Map.drop(attrs, [:email]))
    user
  end

  @doc "Every blob file under the store root, relative to it."
  def blob_files do
    root = Store.root()

    for path <- Path.wildcard(Path.join(root, "**/*"), match_dot: true),
        File.regular?(path),
        do: Path.relative_to(path, root)
  end

  @doc """
  Removes the blobs a test wrote, and leaves the committed demo site's alone.

  The demo base is written once, outside every test's transaction
  (`test_helper.exs`), so wiping the whole store would delete files the suite did
  not create and cannot roll back: a later test that exports the base then finds
  empty attachments. What a test wrote is what was not there when the base was
  written — `test_helper.exs` records that list.
  """
  def clean_blobs do
    root = Store.root()
    base = MapSet.new(:persistent_term.get({__MODULE__, :base_blobs}, []))

    for file <- blob_files(), not MapSet.member?(base, file) do
      File.rm(Path.join(root, file))
    end

    :ok
  end

  @doc "A mirrored space with a generated key unless one is given."
  def space_fixture(attrs \\ %{}) do
    key = Map.get(attrs, :key) || "SP#{System.unique_integer([:positive])}"

    {:ok, space} = Mirror.upsert_space(Map.merge(%{key: key, name: "Space #{key}"}, attrs))
    space
  end

  @doc "A mirrored page (or blog post, with `type: \"blogpost\"`) in a space."
  def page_fixture(%Space{} = space, attrs \\ %{}) do
    id = Map.get(attrs, :confluence_id) || System.unique_integer([:positive])

    defaults = %{
      confluence_id: id,
      title: "Page #{id}",
      slug: "page-#{id}",
      author_name: "Jane Doe",
      external_updated_at: ~U[2026-10-01 12:00:00Z]
    }

    {:ok, page} = Mirror.upsert_page(space, Map.merge(defaults, attrs))
    page
  end

  @doc "A file attached to a mirrored page."
  def attachment_fixture(%Page{} = page, attrs \\ %{}) do
    id = Map.get(attrs, :confluence_id) || to_string(System.unique_integer([:positive]))

    defaults = %{confluence_id: id, page_id: page.id, filename: "file-#{id}.txt", byte_size: 1024}

    {:ok, attachment} =
      %Attachment{}
      |> Attachment.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    attachment
  end

  @doc "A mirrored comment (a reply, with `parent_id`) on a page."
  def comment_fixture(%Page{} = page, attrs \\ %{}) do
    id = Map.get(attrs, :confluence_id) || System.unique_integer([:positive])

    defaults = %{
      confluence_id: id,
      page_id: page.id,
      author_name: "Sam Rivera",
      body_export: "<p>Looks good.</p>",
      body_text: "Looks good.",
      external_created_at: ~U[2026-10-01 12:00:00Z]
    }

    {:ok, comment} =
      %Comment{}
      |> Comment.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    comment
  end
end
