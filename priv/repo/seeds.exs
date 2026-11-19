# Seeds are idempotent: the bundled demo snapshot is only pulled when the database
# is empty and the source is not a live site, and the development administrator
# always exists.
#
# Setup never touches the network. A real Confluence site is mirrored when
# somebody asks for it — `mix confluence.sync`, or the release's startup pull —
# and never as a side effect of creating a database.
alias ConfluencePhxMirror.Accounts
alias ConfluencePhxMirror.Confluence.Source
alias ConfluencePhxMirror.Mirror.Space
alias ConfluencePhxMirror.Repo
alias ConfluencePhxMirror.Sync

cond do
  Repo.aggregate(Space, :count) > 0 ->
    Mix.shell().info("Content already present; skipping the demo sync.")

  Source.kind(Source.source()) == :live ->
    Mix.shell().info("""
    The mirror is empty and this source is a live Confluence site, so setup did
    not sync it. Run `mix confluence.sync` when you want it mirrored.
    """)

  true ->
    Mix.shell().info("Mirroring the bundled demo snapshot…")

    case Sync.run(:snapshot, actor: {:system, "seeds"}) do
      {:ok, run} ->
        Mix.shell().info("Seeded #{run.stats["pages"]} pages in #{run.stats["spaces"]} spaces.")

      {:error, reason} ->
        Mix.raise("Seed sync failed: #{inspect(reason)}")
    end
end

admin = Accounts.ensure_admin!()
Mix.shell().info("Administrator available: #{admin.email}")

if Application.get_env(:confluence_phx_mirror, :auto_admin, false) do
  Mix.shell().info("Auto-admin is enabled: no sign-in needed in this environment.")
end
