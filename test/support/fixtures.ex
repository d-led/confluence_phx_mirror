defmodule ConfluencePhxMirror.Fixtures do
  @moduledoc """
  Test helpers: demo syncs, users and subscriptions.
  """

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Page, Space}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync

  @doc "Mirrors the bundled demo snapshot and returns the finished sync run."
  def demo_snapshot! do
    {:ok, run} = Sync.run(:snapshot)
    run
  end

  @doc "A user with a deterministic e-mail."
  def user_fixture(attrs \\ %{}) do
    email = Map.get(attrs, :email, "reader#{System.unique_integer([:positive])}@example.com")

    {:ok, user} = Accounts.ensure_user(email, Map.drop(attrs, [:email]))
    user
  end

  @doc "Removes blobs written by a test."
  def clean_blobs do
    File.rm_rf!(Store.root())
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
end
