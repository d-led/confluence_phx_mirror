defmodule ConfluencePhxMirror.BuildInfoTest do
  @moduledoc """
  The build a release came from, as the build recorded it — and as `dev` when
  nothing recorded anything.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.BuildInfo

  describe "reading the build file" do
    test "a checkout no build touched says dev" do
      assert BuildInfo.read(empty_dir()) == BuildInfo.dev()
      assert BuildInfo.label(BuildInfo.read(empty_dir())) == "dev"
    end

    test "a build file says what the build was told" do
      dir =
        build_dir(%{
          "version" => "1.2.3",
          "revision" => "3f2a1c9b8e7d6c5b4a39281706f5e4d3c2b1a090",
          "built_at" => "2026-10-23T13:00:00Z",
          "ci" => %{
            "provider" => "github",
            "workflow" => "ci",
            "run_number" => "42",
            "run_url" => "https://github.com/d-led/confluence_phx_mirror/actions/runs/42"
          }
        })

      info = BuildInfo.read(dir)

      assert info.version == "1.2.3"
      assert info.revision == "3f2a1c9b8e7d6c5b4a39281706f5e4d3c2b1a090"
      assert info.built_at == "2026-10-23T13:00:00Z"
      assert info.ci.workflow == "ci"
      assert info.ci.run_number == "42"
    end

    test "an unreadable file is a checkout without a build, not a crash" do
      dir = empty_dir()
      File.write!(Path.join(dir, "build_info.json"), "{not json")

      assert BuildInfo.read(dir) == BuildInfo.dev()
    end
  end

  describe "writing the build file" do
    test "round-trips the build the task collected" do
      dir = empty_dir()

      info = %{
        version: "1.2.3",
        revision: "3f2a1c9b8e7d",
        built_at: "2026-10-23T13:00:00Z",
        ci: %{
          provider: "github",
          workflow: "ci",
          run_number: "42",
          run_url: "https://example.test/runs/42"
        }
      }

      :ok = BuildInfo.write(dir, info)

      assert BuildInfo.read(dir) == info
    end

    test "a build nobody recorded a pipeline for round-trips without one" do
      dir = empty_dir()

      :ok = BuildInfo.write(dir, BuildInfo.dev())

      assert BuildInfo.read(dir) == BuildInfo.dev()
    end
  end

  describe "the label an administrator reads" do
    test "is the version and the short commit" do
      info = info(version: "1.2.3", revision: "3f2a1c9b8e7d6c5b4a39281706f5e4d3")
      assert BuildInfo.label(info) == "1.2.3+3f2a1c9"
    end

    test "is the version alone when there is no commit" do
      assert BuildInfo.label(info(version: "1.2.3", revision: nil)) == "1.2.3"
    end

    test "names the pipeline run, when one built it" do
      assert BuildInfo.ci_label(info(ci: %{workflow: "ci", run_number: "42"})) == "ci #42"
      assert BuildInfo.ci_label(info(ci: %{workflow: "release"})) == "release"
      assert BuildInfo.ci_label(info(ci: nil)) == nil
    end

    test "spells the build out for a tooltip" do
      description =
        BuildInfo.description(
          info(
            version: "1.2.3",
            revision: "3f2a1c9b8e7d",
            built_at: "2026-10-23T13:00:00Z",
            ci: %{run_url: "https://example.test/runs/42"}
          )
        )

      assert description ==
               "version 1.2.3, commit 3f2a1c9, built 2026-10-23T13:00:00Z, " <>
                 "https://example.test/runs/42"
    end
  end

  defp info(overrides) do
    Map.merge(BuildInfo.dev(), Map.new(overrides))
  end

  defp empty_dir do
    # `unique_integer/1` counts from one in every run, and the temp directory
    # outlives the run: without clearing it, "empty" is a directory some earlier
    # run already wrote `build_info.json` into, and the test reads that build.
    dir = Path.join(System.tmp_dir!(), "build-info-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp build_dir(contents) do
    dir = empty_dir()
    File.write!(Path.join(dir, "build_info.json"), :json.encode(contents))
    dir
  end
end
