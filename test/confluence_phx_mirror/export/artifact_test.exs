defmodule ConfluencePhxMirror.Export.ArtifactTest do
  @moduledoc """
  One archive on disk, one build that makes it, and the folder it lives in.

  The build is what a download waits for, so the cases here are the ones a
  screen and a request both depend on: a file appears where the deployment said,
  a second ask while one is running is refused rather than doubled, a finished
  archive is offered instead of rebuilt, and a build that dies leaves nothing
  behind to download.
  """

  use ConfluencePhxMirror.DataCase, async: false

  alias ConfluencePhxMirror.Export.Artifact
  alias ConfluencePhxMirror.TestConfig

  # A registry of this test's own: the application's one keeps the real folder
  # and survives between tests.
  @server :artifact_test

  setup do
    dir = Path.join(System.tmp_dir!(), "artifact-#{System.unique_integer([:positive])}")

    start_supervised!(
      {Artifact, name: @server, dir: dir, keep_ms: 10 * 60 * 1000, sweep_ms: 3_600_000}
    )

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir}
  end

  describe "the folder" do
    test "is the deployment's, when it names one" do
      TestConfig.put(:export_tmp_dir, "/tmp/a-deployment-chose-this")

      assert Artifact.dir() == "/tmp/a-deployment-chose-this/confluence-mirror-exports"

      assert Artifact.path("site.zip") ==
               "/tmp/a-deployment-chose-this/confluence-mirror-exports/site.zip"
    end

    test "is the operating system's temporary folder otherwise" do
      TestConfig.put(:export_tmp_dir, nil)

      assert Artifact.dir() == Path.join(System.tmp_dir!(), "confluence-mirror-exports")
    end
  end

  describe "one build" do
    test "writes the archive and says how big it is", %{dir: dir} do
      assert :started = Artifact.prepare("site.zip", server: @server, build: emitting("hello"))

      assert {:ready, %{bytes: 5}} = wait_for_ready()
      assert File.read!(Path.join([dir, "confluence-mirror-exports", "site.zip"])) == "hello"
    end

    test "reports its progress while it runs" do
      test = self()

      build = fn emit ->
        emit.("first")
        # The build is a process of its own; the test holds it here so the
        # second half is written on purpose rather than whenever.
        send(test, {:half_written, self()})

        receive do
          :carry_on -> emit.(" second")
        after
          5_000 -> :never_asked
        end
      end

      assert :started = Artifact.prepare("site.zip", server: @server, build: build)
      assert_receive {:half_written, builder}, 2_000

      # The bytes on disk are the progress the screen shows, so the count has to
      # be the first batch and not the sum of everything still to come.
      assert soon(fn ->
               match?({:building, %{bytes: 5}}, Artifact.status("site.zip", @server))
             end)

      send(builder, :carry_on)

      assert {:ready, %{bytes: 12}} = wait_for_ready()
    end

    test "is refused while another one is running, and says whose it is" do
      test = self()

      build = fn emit ->
        emit.("first")
        send(test, :half_written)
        Process.sleep(2_000)
      end

      assert :started =
               Artifact.prepare("site.zip", server: @server, by: "ops@example.com", build: build)

      assert_receive :half_written, 2_000

      assert {:busy, "ops@example.com"} =
               Artifact.prepare("site.zip",
                 server: @server,
                 by: "other@example.com",
                 build: build
               )
    end

    test "is not started again while the archive is fresh" do
      assert :started = Artifact.prepare("site.zip", server: @server, build: emitting("hello"))
      assert {:ready, _} = wait_for_ready()

      assert :ready = Artifact.prepare("site.zip", server: @server, build: emitting("again"))
    end

    test "leaves nothing to download when it dies" do
      assert :started = Artifact.prepare("site.zip", server: @server, build: failing())

      assert soon(fn -> Artifact.status("site.zip", @server) == :absent end)
      refute File.exists?(Artifact.path("site.zip"))
    end
  end

  test "forgetting the archive deletes the file and the state", %{dir: dir} do
    assert :started = Artifact.prepare("site.zip", server: @server, build: emitting("hello"))
    assert {:ready, _} = wait_for_ready()

    assert :ok = Artifact.forget(@server)

    assert Artifact.status("site.zip", @server) == :absent
    refute File.exists?(Path.join([dir, "confluence-mirror-exports", "site.zip"]))
  end

  defp emitting(text), do: fn emit -> emit.(text) end

  defp failing, do: fn _emit -> raise "the mirror is not there" end

  defp wait_for_ready do
    status =
      soon_value(fn ->
        case Artifact.status("site.zip", @server) do
          {:ready, _} = ready -> ready
          _not_yet -> nil
        end
      end)

    assert status, "the build never reported a finished archive"
    status
  end

  defp soon(condition), do: soon_value(fn -> condition.() || nil end) != nil

  # A build is a process of its own, so its result arrives when it arrives. Two
  # seconds is longer than writing a few bytes takes by any measure that is not
  # a stop-the-world pause.
  defp soon_value(fun, tries \\ 200) do
    Enum.reduce_while(1..tries, nil, fn _attempt, _acc ->
      case fun.() do
        nil ->
          Process.sleep(10)
          {:cont, nil}

        value ->
          {:halt, value}
      end
    end)
  end
end
