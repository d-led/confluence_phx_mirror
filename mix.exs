defmodule ConfluencePhxMirror.MixProject do
  use Mix.Project

  def project do
    [
      app: :confluence_phx_mirror,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_paths: test_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer(),
      releases: releases()
    ]
  end

  # The desktop bundle carries this release inside it, and macOS will not launch
  # a signed application whose innards are unsigned: Tauri signs the Rust half by
  # itself, and every BEAM binary, port and escript in the release is the other
  # half. `ElixirKit.Release.codesign/1` signs them, ad-hoc when no
  # `APPLE_SIGNING_IDENTITY` is set, which is why this works before anyone has a
  # certificate.
  #
  # Opt-in (`CONFLUENCE_SIGN_RELEASE=1`, set by `scripts/package.sh` and by the
  # desktop workflow): signing 2 700 files on every `mix release` would tax the
  # loop it is not needed in, and a Linux server release has nothing to sign.
  defp releases do
    [
      confluence_phx_mirror: [
        steps: release_steps(),
        # Both flavours of launcher, whichever machine assembles the release.
        # Mix's default is the *assembling* platform's, and the desktop build
        # assembles on three — `src-tauri/src/main.rs` starts
        # `bin/confluence_phx_mirror.bat` on Windows, and a Windows release
        # without one is a window that starts nothing.
        include_executables_for: [:unix, :windows],
        entitlements: "#{__DIR__}/src-tauri/App.entitlements"
      ]
    ]
  end

  defp release_steps do
    if System.get_env("CONFLUENCE_SIGN_RELEASE") == "1" do
      # The entitlements the BEAM needs under the hardened runtime: it compiles
      # code at run time, which is exactly what those switches are for.
      [:assemble, &ElixirKit.Release.codesign/1]
    else
      [:assemble]
    end
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
      mod: {application_module(Mix.env()), []},
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
  #
  # `:desktop` is the export tool: the same `lib/`, its own persistence and
  # supervision tree in `lib_desktop/`. Dev, test and prod do not compile that
  # path, so nothing the server ships contains the desktop code.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:desktop), do: ["lib", "lib_desktop"]
  defp elixirc_paths(_), do: ["lib"]

  # The tool's tests live in their own directory, and in the desktop environment
  # they are the *only* ones: `mix test` loads `<path>/test_helper.exs`, and the
  # server's helper starts a sandbox for a repo the tool does not run in these
  # tests. Two environments, two suites, one command each — `mix test` for the
  # server, `scripts/test-desktop.sh` for the tool.
  defp test_paths(:desktop), do: ["test_desktop"]
  defp test_paths(_), do: ["test"]

  defp application_module(:desktop), do: ConfluencePhxMirror.Desktop.Application
  defp application_module(_), do: ConfluencePhxMirror.Application

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      # The desktop export tool's store — and the engine the suite is run against
      # a second time in CI (`CM_TEST_ADAPTER=sqlite`). `:desktop` and `:test`,
      # never a release the server builds: the driver's C NIF has no business in
      # a server image that talks to Postgres. See docs/desktop-tool.md.
      {:ecto_sqlite3, "~> 0.17", only: [:desktop, :test]},
      # Compiles `native/confluence_keyring` and loads it as a NIF. `:desktop`
      # only, or every server build would need a Rust toolchain for a credential
      # store it does not have.
      {:rustler, "~> 0.38.0", only: :desktop, runtime: false},
      # Signs the release for macOS (`ElixirKit.Release.codesign/1`), the half
      # Tauri cannot sign for itself: the Erlang VM and every escript the release
      # ships. `:desktop` only — the server image is Linux and has nothing to
      # sign. See `release_steps/0`.
      {:elixirkit, "~> 0.1", only: :desktop},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test, "~> 0.14.0", only: :test, runtime: false},
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
      # Every environment but `:desktop`. The library's Makefile has no Windows
      # branch at all — no `-shared`, and it names the result `.so` — so it cannot
      # build on the platform the tool must ship for, and its newest release
      # (4.1.3) is the same. Nothing in the tool hashes or checks a token: it has
      # one local reader, no sign-in, and no API clients. `Accounts.TokenHash`
      # decides what a build without a hasher can do, in one place.
      {:argon2_elixir, "~> 4.1", only: [:dev, :test, :prod]},
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
      # `:desktop` too: the tool is a separate compile of this project, and the
      # one tree no type check had seen was the one that only exists there.
      # `runtime: false`, so it is a build-time tool in that environment and
      # never a dependency of the release.
      {:dialyxir, "~> 1.4", only: [:dev, :test, :desktop], runtime: false},
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
      # Both directories on Postgres; the schema set alone on SQLite, where the
      # manual ones cannot run by nature — they rewrite JSON the way only
      # Postgres spells it, and the tool's own boot runs the same schema set
      # (`Desktop.Setup`). See `config/test.exs` for the adapter switch.
      test: ["ecto.create --quiet", test_migrations(), "test"],
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

  # Which migrations `mix test` applies. `ecto.migrate_all` reaches into
  # `priv/repo/manual_migrations`, which are Postgres-shaped on purpose (a JSON
  # rewrite no other engine has); the SQLite suite runs what the tool runs.
  # Which migrations a test run applies.
  #
  # The deployment's Postgres has two sets: `priv/repo/migrations` and the
  # hand-run `priv/repo/manual_migrations` (statements somebody decides to run,
  # like the one that moves a value out of a `jsonb` column). SQLite has only the
  # first — the manual ones are written in Postgres's jsonb operators, and the
  # tool's own boot applies the same single set (`Desktop.Setup`). A desktop test
  # run that applied both failed on the first statement of a migration the app
  # never runs, which is the sort of thing a test environment exists to tell you:
  # the alias and the boot were disagreeing about which migrations a workspace
  # has.
  defp test_migrations do
    if sqlite_store?(), do: "ecto.migrate --quiet", else: "ecto.migrate_all --quiet"
  end

  # SQLite is the store either because the second CI leg asks for it, or because
  # this is the desktop environment, where it is the only adapter there is.
  defp sqlite_store? do
    System.get_env("CM_TEST_ADAPTER") == "sqlite" or Mix.env() == :desktop
  end
end
