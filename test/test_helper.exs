# The scale suite builds a mirror a thousand spaces wide before it measures
# anything, so it is opt-in: `mix test --only scale` (see `scale_test.exs`).
ExUnit.start(exclude: [:scale])
Ecto.Adapters.SQL.Sandbox.mode(ConfluencePhxMirror.Repo, :manual)
