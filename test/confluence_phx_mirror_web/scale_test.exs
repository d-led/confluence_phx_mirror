defmodule ConfluencePhxMirrorWeb.ScaleTest do
  @moduledoc """
  What a reader's request costs when the mirror is large.

  The rest of the suite runs over the bundled demo snapshot — a dozen pages — and
  a page view that quietly loads a whole space, or a home page that counts a
  million rows, looks exactly like a fast one there. This suite builds the mirror
  the numbers are supposed to hold for: a thousand spaces of a thousand pages,
  unless told otherwise.

      mix setup                                    # once, to create the databases
      MIX_TEST_PARTITION=scale mix test --only scale

  Sizes come from the environment, so a run while working stays cheap:

      CM_SCALE_SPACES=20 CM_SCALE_PAGES=200 MIX_TEST_PARTITION=scale mix test --only scale

  Every case reports the statements it issued, the time each statement took and
  the size of the response, then holds the statement count to a budget. Wall
  time is reported but not asserted: a laptop under load is not a regression.
  The response size *is* asserted, because fetching a whole space and rendering
  it is a shape problem, not a speed problem.

  Set `CM_PROFILE=1` to also profile a page view with `:cprof` (call counts) and
  `:eprof` (time per function) — the two tools the AppSignal profiling article
  recommends for exactly this question.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias ConfluencePhxMirror.Confluence.SyntheticContent
  alias ConfluencePhxMirror.Fixtures
  alias ConfluencePhxMirror.Measure
  alias ConfluencePhxMirror.QueryCounter
  alias ConfluencePhxMirror.Synthetic

  @endpoint ConfluencePhxMirrorWeb.Endpoint

  @moduletag :scale
  @moduletag timeout: :infinity

  # A reader's page view is one controller action: the shell, the page, its
  # breadcrumbs, its children, attachments, comments, backlinks, links and the
  # two subscription questions. The ceiling is what the code spends today, so it
  # can only go down.
  @page_view_budget 16
  @space_overview_budget 13
  @catalog_budget 13
  @home_budget 15
  @search_budget 18

  # A response that carries the whole space is megabytes; a page view that
  # carries one page, its branch and its rail is tens of kilobytes.
  @page_view_bytes 120_000
  @home_bytes 120_000
  @catalog_bytes 150_000

  # A statement count is exact; a stopwatch is not. This ceiling only catches a
  # read that went from bounded to scanning a million rows.
  @sanity_ms 3_000

  setup_all do
    # A million rows is a few minutes of writing inside one transaction, which is
    # longer than the sandbox's default ownership timeout allows.
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(ConfluencePhxMirror.Repo,
        shared: true,
        ownership_timeout: 1_800_000
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    opts = options()
    %{spaces: spaces, pages: pages} = Synthetic.seed!(opts)

    report("scale fixture", [
      {"spaces", spaces},
      {"pages", pages},
      {"pages per space", opts[:pages_per_space]},
      {"branching", opts[:branching]}
    ])

    # A reader, not the development administrator: the administrator short-cuts
    # every permission question, and asking it is part of what a page view does.
    reader = Fixtures.user_fixture(%{email: "scale-reader@example.com"})

    {:ok, opts: opts, reader: reader}
  end

  test "a page view reads one page, not its space", %{opts: opts, reader: reader} do
    path = SyntheticContent.page_path(opts[:spaces], opts[:pages_per_space])
    measurement = measure(reader, path)

    report("a page view, the last page of the last space", measurement)

    assert measurement.queries.count <= @page_view_budget
    assert measurement.bytes <= @page_view_bytes
    assert measurement.max_ms <= @sanity_ms
  end

  test "a page at the root of a space costs what one deep in it costs", %{reader: reader} do
    root = measure(reader, SyntheticContent.page_path(1, 1))
    deep = measure(reader, SyntheticContent.page_path(1, 5))

    report("a root page", root)
    report("a deep page", deep)

    assert root.queries.count == deep.queries.count
    assert root.max_ms <= @sanity_ms
    assert deep.max_ms <= @sanity_ms
  end

  test "the home page reports the mirror without reading every page", %{
    opts: opts,
    reader: reader
  } do
    measurement = measure(reader, "/")
    report("the home page", measurement)

    assert measurement.queries.count <= @home_budget
    assert measurement.bytes <= @home_bytes
    assert measurement.max_ms <= @sanity_ms
    assert measurement.body =~ "#{opts[:spaces] * opts[:pages_per_space]} pages"
  end

  test "the space overview does not read every page's body", %{reader: reader} do
    measurement = measure(reader, "/spaces/#{SyntheticContent.space_key(1)}/overview")
    report("a space overview", measurement)

    assert measurement.queries.count <= @space_overview_budget
    assert measurement.max_ms <= @sanity_ms
  end

  test "a catalog returns one page of rows", %{opts: opts, reader: reader} do
    measurement = measure(reader, "/spaces/#{SyntheticContent.space_key(1)}/pages")
    report("a space catalog", measurement)

    assert measurement.queries.count <= @catalog_budget
    assert measurement.bytes <= @catalog_bytes
    assert measurement.max_ms <= @sanity_ms
    assert opts[:pages_per_space] > 0
  end

  test "search is paged in the database", %{reader: reader} do
    measurement = measure(reader, "/search?q=Page")
    report("search", measurement)

    assert measurement.queries.count <= @search_budget
    assert measurement.max_ms <= @sanity_ms
  end

  test "a page view profiles cleanly", %{opts: opts, reader: reader} do
    path = SyntheticContent.page_path(opts[:spaces], opts[:pages_per_space])

    if System.get_env("CM_PROFILE") do
      profile(reader, path)
    else
      IO.puts("  (set CM_PROFILE=1 to profile a page view with cprof and eprof)")
    end
  end

  # ---------------------------------------------------------------------------
  # Measuring
  # ---------------------------------------------------------------------------

  defp measure(reader, path) do
    {_conn, queries} = QueryCounter.collect(fn -> request(reader, path) end)
    timings = Measure.timings(fn -> request(reader, path) end)
    body = timings.result.resp_body

    %{
      path: path,
      body: body,
      bytes: byte_size(body),
      median_ms: timings.median_ms,
      max_ms: timings.max_ms,
      queries: QueryCounter.summarize(queries)
    }
  end

  defp request(reader, path) do
    build_conn()
    |> init_test_session(%{user_id: reader.id})
    |> get(path)
  end

  defp report(title, %{} = measurement) do
    IO.puts("\n  #{title}")

    IO.puts(
      "    #{measurement.median_ms} ms median, #{measurement.max_ms} ms worst, " <>
        "#{Measure.kb(measurement.body)} KB"
    )

    IO.puts(QueryCounter.format(measurement.queries))
  end

  defp report(title, rows) when is_list(rows) do
    IO.puts("\n  #{title}")
    Enum.each(rows, fn {label, value} -> IO.puts("    #{label}: #{value}") end)
  end

  # `:cprof` counts calls (cheap); `:eprof` times them (slower, but it says where
  # the milliseconds go). Both report to stdout, so the profile is the output.
  defp profile(reader, path) do
    IO.puts("\n  cprof — the most-called functions of one page view")
    :cprof.start()
    request(reader, path)
    :cprof.stop()
    :cprof.analyse() |> crowded() |> Enum.each(&IO.puts("    #{inspect(&1)}"))

    IO.puts("\n  eprof — time per function for one page view")
    :eprof.start_profiling([self()])
    request(reader, path)
    :eprof.stop_profiling()
    :eprof.analyze(:total, sort: :time)
  end

  defp crowded({_total, modules}) do
    modules
    |> Enum.filter(fn {module, _count} -> mirror_module?(module) end)
    |> Enum.take(10)
  end

  defp crowded(other), do: [other]

  defp mirror_module?(module) when is_atom(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.ConfluencePhxMirror")
  end

  defp mirror_module?(_other), do: false

  defp options do
    [
      spaces: env("CM_SCALE_SPACES", 1_000),
      pages_per_space: env("CM_SCALE_PAGES", 1_000),
      branching: env("CM_SCALE_BRANCHING", 10)
    ]
  end

  defp env(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> String.to_integer(value)
    end
  end
end
