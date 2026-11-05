# Mix tasks and aliases

Two kinds of command, in two different places: the tasks this project ships in
`lib/mix/tasks/`, and the aliases in `mix.exs` that chain them. `mix help <name>`
prints the same thing the task's own moduledoc does; this page is the index.

## Tasks

| Task | What it does | Arguments |
|---|---|---|
| `mix confluence.sync` | Mirrors the source's content into this database — the same pipeline the scheduler and the webhooks use. Starts the app. | `--mode snapshot\|incremental\|space\|page` (default **`snapshot`**), `--space KEY` (required by `space`), `--page ID` (required by `page`), `--since ISO8601` (`incremental`, defaults to one interval ago) |
| `mix confluence.probe` | Checks the configured base URL and credentials and says what came back. | none |
| `mix confluence.webhook` | Sends a signed test webhook to the mirror, as Confluence would. | `--page ID` (**required**), `--event NAME` (default `page_updated`), `--url URL` (default: this deployment's own intake) |
| `mix mirror.site` | Shows the database the configured Confluence site maps to, creating it on request. | `--create` |
| `mix mirror.blobs.sweep` | Frees the attachment bytes no row refers to any more. | `--force` (actually delete), `--if-older-than SECONDS` |
| `mix assets.install` | Installs the esbuild and tailwind CLIs, both from GitHub releases. | `--if-missing` (used by `assets.setup`) |
| `mix build.info` | Burns the version, the commit and the pipeline run into `priv/`. | none |
| `mix lint.sobelow` | Runs Sobelow and attributes the `mix.lock` parser warning it cannot avoid. | `--config` |

Three details that are easy to get wrong:

* **`--mode` defaults to `snapshot`**, not to an incremental pass. A bare
  `mix confluence.sync` therefore re-reads the listing rather than picking up
  where the last run stopped.
* **`--mode page` means what it says**: it forces the page through the live-doc
  floor that keeps a webhook from re-reading a page a reader is editing, because
  somebody at a prompt asked for exactly that page.
* **`mirror.blobs.sweep` is a dry run until `--force`.** It prints what it would
  free; it frees nothing.

## Aliases

| Alias | Runs |
|---|---|
| `mix lint` | `compile --warnings-as-errors`, `deps.unlock --check-unused`, `format --check-formatted`, `credo --strict`, `lint.sobelow --config` — static analysis only, no database |
| `mix test` | `ecto.create --quiet`, the migrations for this engine, then `test`. Drops nothing: it creates and migrates, and your data stays |
| `mix cover` | Prettier over `assets/`, then `test --cover --export-coverage default` |
| `mix complexity` | `mix crap` over `lib/confluence_phx_mirror` and `lib/confluence_phx_mirror_web`, max score 30 |
| `mix types` | `dialyzer` |
| `mix precommit` | `scripts/quality.sh` — lint, cover and complexity in one report, in the order that fails fastest |
| `mix setup` | `deps.get`, `ecto.setup`, `assets.setup`, `assets.build` |
| `mix ecto.setup` | `ecto.create`, `ecto.migrate_all`, `priv/repo/seeds.exs` |
| `mix ecto.migrate_all` | Migrations from **both** directories: `priv/repo/migrations` and `priv/repo/manual_migrations` |
| `mix ecto.reset` | `ecto.drop`, `ecto.setup` — destroys this site's data |
| `mix assets.setup` | `assets.install --if-missing` |
| `mix assets.build` | `npm ci`, `compile`, tailwind, both esbuild bundles |
| `mix assets.deploy` | The same, minified, plus `phx.digest` |

`types` and `cover` are separate aliases rather than parts of `lint` because
they are slow: the PLT costs two minutes cold and ten seconds warm, and the
suite needs a database. `scripts/quality.sh` takes `--fast` (static analysis
only), `--no-tests` (re-rank the coverage already exported), `--top N` and
`--image`, and exits non-zero if any gate fails.

The migration split is deliberate: `priv/repo/manual_migrations` holds the
Postgres-shaped ones (JSON rewrites, slow or destructive), so dev and test apply
both directories while the SQLite desktop build applies the schema set alone.
