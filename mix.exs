defmodule ConfluencePhxMirror.MixProject do
  use Mix.Project

  def project do
    [
      app: :confluence_phx_mirror,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer()
    ]
  end

  # The type check runs in whatever environment calls it — CI runs the whole
  # workflow with `MIX_ENV=test` — and in `:test` the app compiles `test/support`
  # as well. `:mix` is what makes `mix.exs` itself typed (the version string comes
  # from `Mix.Project`), and `:ex_unit` is what the case templates in
  # `test/support` need. The asset CLIs and `phoenix_test` are `runtime: false` in
  # this environment — compiled, but absent from the app's applications — so
  # dialyzer has to be told to load them, or `mix assets.install` and the
  # feature cases show up as calls to functions that do not exist.
  defp dialyzer do
    [plt_add_apps: [:mix, :ex_unit, :esbuild, :tailwind] ++ test_plt_apps(Mix.env())]
  end

  defp test_plt_apps(:test), do: [:phoenix_test]
  defp test_plt_apps(_env), do: []

  defp package do
    [
      licenses: ["MPL-2.0"],
      description: "A read-only, searchable mirror of a Confluence site."
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ConfluencePhxMirror.Application, []},
      # os_mon is what answers "how much memory is left": memsup samples the
      # machine, which is the number the admin overview shows next to the
      # mirror's own heap. It also raises a system alarm when the disk or the
      # memory crosses its watermark, which lands in the log for free.
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  def cli do
    [
      # The test-shaped aliases run against the test environment, the way
      # `mix test` itself does.
      preferred_envs: [cover: :test, complexity: :test, precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test, "~> 0.13.1", only: :test, runtime: false},
      {:phoenix_live_dashboard, "~> 0.9.1"},
      # The dashboard's Ecto Stats page — index usage, sequential scans, cache
      # hits, bloat — is a browser over this package's queries, and it offers no
      # repository at all unless the module is loadable on the node showing the
      # page. In the release too, then: the page is on wherever `admin_dashboard`
      # is on, and that is production; without the module the page is still
      # there and says it found no repository, which is how it shipped once.
      {:ecto_psql_extras, "~> 0.8"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.7.50",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.3"},
      {:argon2_elixir, "~> 4.1"},
      {:req, "~> 0.5"},
      {:floki, "~> 0.38"},
      # Converted page bodies, for the MCP server and its repeated reads of one
      # page. Entries are keyed by content, so a sync that changes a body
      # simply misses rather than needs invalidating.
      {:cachex, "~> 4.1"},
      {:hammer, "~> 7.5"},
      {:oban, "~> 2.20"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:ex_crap, "~> 0.1.1", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      # Migrations come in two directories: the ones that must run on deploy and
      # the manual ones (slow, destructive, data). Dev and test want both.
      "ecto.migrate_all":
        "ecto.migrate --migrations-path=priv/repo/migrations --migrations-path=priv/repo/manual_migrations",
      "ecto.setup": ["ecto.create", "ecto.migrate_all", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate_all --quiet", "test"],
      "assets.setup": ["assets.install --if-missing"],
      "assets.build": [
        "cmd --cd assets npm ci",
        "compile",
        "tailwind confluence_phx_mirror",
        "esbuild confluence_phx_mirror",
        "esbuild confluence_phx_mirror_swagger"
      ],
      "assets.deploy": [
        "cmd --cd assets npm ci",
        "tailwind confluence_phx_mirror --minify",
        "esbuild confluence_phx_mirror --minify",
        "esbuild confluence_phx_mirror_swagger --minify",
        "phx.digest"
      ],
      # Static analysis: no database, no test run, under a few seconds. Read-only
      # on purpose — a check that rewrites files cannot run in CI.
      lint: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "lint.sobelow --config"
      ],
      # The type check: dialyzer against a PLT of OTP, Elixir and the deps. Its
      # own alias rather than part of `lint`, because the PLT costs two minutes
      # on a cold machine and `lint` promises seconds. `:mix` and `:ex_unit` are
      # in the PLT (see `dialyzer:` above) so the version and the app's own
      # `Mix.Project` are typed too, not just the app.
      types: ["dialyzer"],
      # Tests with the coverage data the complexity gate needs.
      #
      # The suite formats the assets first: `mix format` owns Elixir and HEEx and
      # never looks at what esbuild ships, so `assets/` is Prettier's half — and
      # it is written, not checked, because a test run that stops on style is a
      # test run that did not happen. `npm --prefix assets ci` is what makes it
      # runnable; `assets.build` needs it anyway.
      cover: [
        "cmd --cd assets npm run --silent prettier",
        "test --cover --export-coverage default"
      ],
      # CRAP scores every function by complexity and coverage; it reads the
      # exported coverage, so it runs after `mix cover`. The conventional
      # threshold applies to the application code — the operator CLIs in
      # lib/mix/tasks are exercised by hand, not by the suite.
      #
      # `cmd` on purpose: Mix refuses to run a task twice in one invocation, so
      # two plain `crap` entries would silently check only the first path.
      complexity: [
        "cmd mix crap --path lib/confluence_phx_mirror --max-score 30 --verbose",
        "cmd mix crap --path lib/confluence_phx_mirror_web --max-score 30 --verbose"
      ],
      # What CI runs: the report script, which chains lint, cover and complexity
      # and prints one summary. `mix lint` and `mix cover` stay available alone.
      precommit: ["cmd scripts/quality.sh"]
    ]
  end
end
