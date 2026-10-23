defmodule Mix.Tasks.Build.Info do
  @shortdoc "Burns the version, the commit and the pipeline run into priv/"

  @moduledoc """
  Writes `priv/build_info.json`, which travels inside the release and is what
  `ConfluencePhxMirror.BuildInfo` reports in the admin footer.

      mix build.info

  Everything comes from the environment, so a build says what it was *told*:

    * `BUILD_VERSION` — defaults to `git describe --tags --always --dirty`,
      or `dev` where there is no git (a Docker build context, for instance)
    * `BUILD_REVISION` — defaults to `git rev-parse --short HEAD`
    * `BUILD_BUILT_AT` — defaults to now, UTC
    * `BUILD_CI_PROVIDER`, `BUILD_CI_WORKFLOW`, `BUILD_CI_RUN_NUMBER`,
      `BUILD_CI_RUN_URL` — set by the pipeline that runs the build; all unset
      means "built by hand", and the footer says `dev` or the git description
      without a run to link to.

  The file is gitignored: it describes one build of one checkout, and a checked
  in copy would be a lie about every other.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    info = build_info()
    ConfluencePhxMirror.BuildInfo.write("priv", info)

    Mix.shell().info("priv/build_info.json: #{info.version} (#{info.revision || "no revision"})")

    :ok
  end

  @doc false
  # Separated from `run/1` so the environment contract can be read, and tested,
  # without a release being built.
  @spec build_info() :: ConfluencePhxMirror.BuildInfo.t()
  def build_info do
    %{
      version: version(),
      revision: env("BUILD_REVISION", git("rev-parse", ["--short", "HEAD"])),
      built_at: env("BUILD_BUILT_AT", DateTime.utc_now() |> DateTime.to_iso8601()),
      ci: ci()
    }
  end

  defp version do
    env("BUILD_VERSION", git("describe", ["--tags", "--always", "--dirty"]) || "dev")
  end

  defp ci do
    ci =
      %{
        provider: System.get_env("BUILD_CI_PROVIDER"),
        workflow: System.get_env("BUILD_CI_WORKFLOW"),
        run_number: System.get_env("BUILD_CI_RUN_NUMBER"),
        run_url: System.get_env("BUILD_CI_RUN_URL")
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Map.new()

    if ci == %{}, do: nil, else: ci
  end

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> value
    end
  end

  # A build context usually has no .git, and that is not an error: it is why the
  # image passes the values in as build arguments.
  defp git(command, args) do
    case System.cmd("git", [command | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {_output, _status} -> nil
    end
  rescue
    ErlangError -> nil
  end
end
