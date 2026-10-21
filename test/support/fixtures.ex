defmodule ConfluencePhxMirror.Fixtures do
  @moduledoc """
  Test helpers: demo syncs, users and subscriptions.
  """

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Blobs.Store
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
end
