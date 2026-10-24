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
      listeners: [Phoenix.CodeReloader]
    ]
  end

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
      extra_applications: [:logger, :runtime_tools]
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
      {:phoenix_test, "~> 0.12.1", only: :test, runtime: false},
      {:phoenix_live_dashboard, "~> 0.9.1"},
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
       tag: "v5.5.20",
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
        "esbuild confluence_phx_mirror"
      ],
      "assets.deploy": [
        "cmd --cd assets npm ci",
        "tailwind confluence_phx_mirror --minify",
        "esbuild confluence_phx_mirror --minify",
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
      # Tests with the coverage data the complexity gate needs.
      cover: ["test --cover --export-coverage default"],
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
