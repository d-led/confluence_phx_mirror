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
    * `BUILD_BUILT_AT` — defaults to now, on the clock of the machine that
      builds, in the offset it was running in: `2026-11-05 06:23+01:00`
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
      built_at: env("BUILD_BUILT_AT", built_now()),
      ci: ci()
    }
  end

  @doc false
  # When the build happened, written the way the person reading it says it:
  # `2026-11-05 06:23+01:00`. `Z` would be one conversion away from the time they
  # remember, and a build often happens in a different zone from the one it is
  # read in.
  @spec stamp(DateTime.t(), integer()) :: String.t()
  def stamp(datetime, offset_seconds) do
    clock =
      datetime |> DateTime.add(offset_seconds, :second) |> Calendar.strftime("%Y-%m-%d %H:%M")

    clock <> offset(offset_seconds)
  end

  defp built_now, do: stamp(DateTime.utc_now(), local_offset())

  # The offset in force now, daylight saving included: local and universal time
  # are both asked of the operating system, and the difference is the offset.
  # Rounded to a quarter hour because every real offset is one of those and the
  # two clocks are read a moment apart — unrounded, a boundary turns `+01:00`
  # into `+00:59`.
  defp local_offset do
    seconds =
      :calendar.datetime_to_gregorian_seconds(:calendar.local_time()) -
        :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())

    round(seconds / 900) * 900
  end

  defp offset(seconds) when seconds < 0, do: "-" <> hours_and_minutes(-seconds)

  defp offset(seconds), do: "+" <> hours_and_minutes(seconds)

  defp hours_and_minutes(seconds) do
    minutes = div(seconds, 60)

    [div(minutes, 60), rem(minutes, 60)]
    |> Enum.map_join(":", &(&1 |> Integer.to_string() |> String.pad_leading(2, "0")))
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
