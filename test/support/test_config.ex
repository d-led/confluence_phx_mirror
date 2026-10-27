defmodule ConfluencePhxMirror.TestConfig do
  @moduledoc """
  Changes the application environment for one test, and puts it back.

  The environment is global: two tests that write it while running beside each
  other overwrite one another's deployment. That is why the suite does not
  switch flags to get an identity — it signs one in (`ConnCase.log_in/2`), and
  `config/test.exs` keeps `auto_admin: false`.

  What is left is the handful of tests that are *about* a deployment: a mirror
  configured against a real Confluence site, a deployment with a seeded
  administrator, a source that fails on purpose. Those tests must be
  `async: false`, and they set the value through here, because this is the only
  place in the suite that writes the environment. The first `put/3` of a key
  remembers what the deployment had and registers the restore with ExUnit, so a
  test cannot save the wrong value, cannot overwrite an original on a second
  write, and cannot forget to put it back — a leaked `:admins` once made four
  unrelated last-admin tests see a second administrator.

      setup do
        TestConfig.put(:admins, ["ops@example.com"])
        :ok
      end

      # or, for one expression rather than the whole test:
      TestConfig.with(admins: [], fn -> assert Admins.admins() == [] end)
  """

  @app :confluence_phx_mirror

  @doc "Sets a key of this application for the rest of the test."
  @spec put(atom(), term()) :: :ok
  def put(key, value), do: put(@app, key, value)

  @doc "Sets a key of `app` for the rest of the test."
  @spec put(atom(), atom(), term()) :: :ok
  def put(app, key, value) do
    remember(app, key)
    Application.put_env(app, key, value)
  end

  @doc """
  Runs `fun` with `pairs` set, and puts them back before it returns.

  For a deployment only one expression needs — the source a single call reads,
  say — where an `on_exit` would outlive the question being asked.
  """
  @spec with(keyword(), (-> result)) :: result when result: term()
  def with(pairs, fun) do
    originals = Enum.map(pairs, fn {key, _value} -> {key, Application.fetch_env(@app, key)} end)

    try do
      Enum.each(pairs, fn {key, value} -> put(key, value) end)
      fun.()
    after
      Enum.each(originals, fn {key, original} -> restore(@app, key, original) end)
    end
  end

  # Remembered once per key: setting a key twice in one test must still restore
  # what the deployment had, not the first value the test set.
  defp remember(app, key) do
    case Process.get({__MODULE__, app, key}) do
      nil ->
        original = Application.fetch_env(app, key)
        Process.put({__MODULE__, app, key}, original)
        ExUnit.Callbacks.on_exit(fn -> restore(app, key, original) end)

      _already_remembered ->
        :ok
    end
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
