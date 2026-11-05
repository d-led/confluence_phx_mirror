[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  # `lib_desktop` is the export tool: it compiles only under `MIX_ENV=desktop`,
  # and `mix format` has to be told about it or the one tree nobody formats is
  # the one tree nobody reads.
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,lib_desktop,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
