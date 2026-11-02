# Archive layout: one directory, or fan-out?
#
#   mix run --no-start scripts/bench/archive_layout_bench.exs
#   N=300000 mix run --no-start scripts/bench/archive_layout_bench.exs
#
# A space can hold a million pages; with Markdown beside them and two or three
# attachments each, an archive is a few million files. Two layouts are measured
# here — everything in one directory, and two levels of fan-out (10,000 buckets)
# — because those are the extremes and the middle has to sit between them.
#
# Method. This is the third version of this script; the first two were wrong in
# ways worth remembering:
#
#   * The first called `mkdir_p` per file in the sharded arm and "found" a 15x
#     regression, which was 100,000 redundant `mkdir` calls.
#   * The second ran both arms into one volume, so the second was measured on a
#     fuller disk than the first.
#
# So: each arm gets a clean directory and is deleted before the other runs;
# bucket creation is timed separately from writing; and the bucket list is
# derived from the shards the ids actually use, so a write can never land in a
# directory the setup forgot. Files are small on purpose — this measures
# directories, not disks.

alias ConfluencePhxMirror.Export.Site

n = System.get_env("N", "100000") |> String.to_integer()

# A directory of its own, per run. A fixed name means two runs of this script
# delete each other's files mid-write, which reads as "no such file or
# directory" for a directory that was created a moment ago — and costs an hour
# of looking at the wrong thing.
root = Path.join(System.tmp_dir!(), "archive-layout-bench-#{System.unique_integer([:positive])}")

File.rm_rf!(root)
File.mkdir_p!(root)

body = :binary.copy("x", 200)

timed = fn fun ->
  {microseconds, _} = :timer.tc(fun)
  microseconds / 1_000_000
end

# ---------------------------------------------------------------------------
# One directory
# ---------------------------------------------------------------------------

flat_dir = Path.join(root, "flat")
File.mkdir_p!(flat_dir)

flat_write =
  timed.(fn ->
    for i <- 1..n, do: File.write!(Path.join(flat_dir, "#{i}.html"), body)
  end)

flat_list = timed.(fn -> File.ls!(flat_dir) end)
File.rm_rf!(flat_dir)

# ---------------------------------------------------------------------------
# Two levels of fan-out
# ---------------------------------------------------------------------------

deep_dir = Path.join(root, "deep")

shards = for i <- 1..n, into: MapSet.new(), do: Site.shard(i)

deep_buckets =
  timed.(fn ->
    Enum.each(shards, fn {first, second} ->
      File.mkdir_p!(Path.join([deep_dir, first, second]))
    end)
  end)

deep_write =
  timed.(fn ->
    for i <- 1..n do
      {first, second} = Site.shard(i)
      File.write!(Path.join([deep_dir, first, second, "#{i}.html"]), body)
    end
  end)

deep_list = timed.(fn -> File.ls!(deep_dir) end)
File.rm_rf!(deep_dir)

# ---------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------

format = fn seconds -> :io_lib.format("~6.2f", [seconds]) |> to_string() end

IO.puts("#{n} files, #{inspect(:os.type())}")
IO.puts("")
IO.puts("                     flat    2 levels")
IO.puts("write files     #{format.(flat_write)}s    #{format.(deep_write)}s")
IO.puts("create buckets  #{format.(0.0)}s    #{format.(deep_buckets)}s")
IO.puts("list root       #{format.(flat_list)}s    #{format.(deep_list)}s")
IO.puts("")
IO.puts("directories            1        #{MapSet.size(shards)}")
IO.puts("per directory      #{n}    #{div(n, max(MapSet.size(shards), 1))}")
IO.puts("")
IO.puts("write ratio: #{Float.round(deep_write / max(flat_write, 0.0001), 2)}x flat")

File.rm_rf!(root)
