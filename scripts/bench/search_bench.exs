# A micro-benchmark of the reader's search path, run before and after a change.
#
#     MIX_ENV=dev mix run scripts/bench/search_bench.exs
#
# It times `Mirror.Search.text/2` — the function the header box, the search page
# and the API all go through — for a handful of query shapes: a word that exists
# as a prefix, one that only exists inside a word, a phrase, and a single letter.
# Each query runs a warm-up, then N timed calls; the report is min / median / p95
# in milliseconds, next to the number of hits, because a query that got faster by
# finding fewer pages is not a win.

alias ConfluencePhxMirror.Mirror.Search

queries = [
  {"exact-ish prefix", "escal"},
  {"inside a word", "scal"},
  {"common word", "certificate"},
  {"two words (AND)", "certificate rotation"},
  {"one letter", "z"},
  {"nothing matches", "zzzqqq"}
]

repeats = 30

warmup = fn query ->
  {:ok, _} = Search.text(query, limit: 20)
end

timed = fn query, times ->
  for _ <- 1..times do
    {micros, {:ok, results}} = :timer.tc(fn -> Search.text(query, limit: 20) end)
    {micros / 1000, length(results)}
  end
end

percentile = fn sorted, fraction ->
  Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * fraction)))
end

IO.puts("search.text/2, limit 20, #{repeats} runs each\n")

IO.puts(
  String.pad_trailing("query", 20) <>
    String.pad_leading("min", 8) <>
    String.pad_leading("median", 9) <>
    String.pad_leading("p95", 8) <> String.pad_leading("hits", 6)
)

for {label, query} <- queries do
  warmup.(query)

  runs = timed.(query, repeats)
  times = runs |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  hits = runs |> List.last() |> elem(1)

  IO.puts(
    String.pad_trailing("#{label} \"#{query}\"", 20) <>
      String.pad_leading(:erlang.float_to_binary(Enum.min(times), decimals: 2), 8) <>
      String.pad_leading(:erlang.float_to_binary(percentile.(times, 0.5), decimals: 2), 9) <>
      String.pad_leading(:erlang.float_to_binary(percentile.(times, 0.95), decimals: 2), 8) <>
      String.pad_leading(Integer.to_string(hits), 6)
  )
end
