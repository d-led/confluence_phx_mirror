# Archive layout: one directory, or two levels of fan-out?
#
#   mix run --no-start scripts/bench/archive_layout_bench.exs
#   N=200000 mix run --no-start scripts/bench/archive_layout_bench.exs
#
# A space can hold a million pages. With Markdown alongside, and two or three
# attachments each, an archive is a few million files — so the question is not
# whether the layout matters but how much. This measures, on the filesystem in
# front of you, the two things that go wrong when a directory holds everything:
# writing into it, and listing it.
#
# Files are small on purpose. This measures the directory, not the disk: a page's
# size changes how long the bytes take to reach the platter, and says nothing
# about whether a directory can hold a million entries.

alias ConfluencePhxMirror.Export.Site

n = System.get_env("N", "100000") |> String.to_integer()
root = Path.join(System.tmp_dir!(), "archive-layout-bench")

File.rm_rf!(root)
File.mkdir_p!(root)

flat = Path.join(root, "flat")
sharded = Path.join(root, "sharded")

body = :binary.copy("x", 200)

timed = fn fun ->
  {microseconds, _} = :timer.tc(fun)
  Float.round(microseconds / 1_000_000, 2)
end

IO.puts("writing #{n} files each way, on #{inspect(:os.type())}…")

flat_write =
  timed.(fn ->
    File.mkdir_p!(flat)
    for i <- 1..n, do: File.write!(Path.join(flat, "#{i}.html"), body)
  end)

sharded_write =
  timed.(fn ->
    for i <- 1..n do
      {first, second} = Site.shard(i)
      directory = Path.join([sharded, first, second])
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "#{i}.html"), body)
    end
  end)

flat_list = timed.(fn -> File.ls!(flat) end)
{first, second} = Site.shard(1)
shard_list = timed.(fn -> File.ls!(Path.join([sharded, first, second])) end)

flat_stat = timed.(fn -> File.stat!(Path.join(flat, "1.html")) end)
shard_stat = timed.(fn -> File.stat!(Path.join([sharded, first, second, "1.html"])) end)

IO.puts("")

IO.puts(
  "write          flat #{flat_write}s   sharded #{sharded_write}s   (#{Float.round(flat_write / max(sharded_write, 0.01), 1)}x)"
)

IO.puts("list 1 dir     flat #{flat_list}s   one shard #{shard_list}s")
IO.puts("stat 1 file    flat #{flat_stat}s   sharded #{shard_stat}s")
IO.puts("")
IO.puts("directories:   flat 1   sharded #{length(File.ls!(sharded)) * 100}")
IO.puts("per directory: flat #{n}   sharded ~#{div(n, max(length(File.ls!(sharded)), 1))}")

# A million pages is ten of these runs, and four and a half million files once
# Markdown and attachments are counted. Linear extrapolation is generous — real
# filesystems degrade faster than that as a directory grows — so treat these as
# a floor.
IO.puts("")
IO.puts("extrapolated to 1M pages (2 files each) + 2.5M attachments:")

for {label, seconds} <- [{"flat write", flat_write}, {"sharded write", sharded_write}] do
  IO.puts("  #{label}: #{Float.round(seconds * 50 / 60, 1)} minutes")
end

File.rm_rf!(root)
