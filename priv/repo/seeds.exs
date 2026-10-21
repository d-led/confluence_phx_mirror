# Seeds are idempotent: the demo snapshot is only pulled when the database is
# empty, and the development administrator always exists.
#
# For a real Confluence site, start the app with CM_SOURCE=http plus
# CM_CONFLUENCE_SITE / CM_ATL_EMAIL / CM_ATL_TOKEN and run:
#
#     mix confluence.sync

alias ConfluencePhxMirror.Accounts
alias ConfluencePhxMirror.Mirror.Space
alias ConfluencePhxMirror.Repo
alias ConfluencePhxMirror.Sync

if Repo.aggregate(Space, :count) == 0 do
  Mix.shell().info("Mirroring the bundled demo snapshot…")

  case Sync.run(:snapshot, actor: {:system, "seeds"}) do
    {:ok, run} ->
      Mix.shell().info("Seeded #{run.stats["pages"]} pages in #{run.stats["spaces"]} spaces.")

    {:error, reason} ->
      Mix.raise("Seed sync failed: #{inspect(reason)}")
  end
else
  Mix.shell().info("Content already present; skipping the demo sync.")
end

admin = Accounts.ensure_admin!()
Mix.shell().info("Administrator available: #{admin.email}")

if Application.get_env(:confluence_phx_mirror, :auto_admin, false) do
  Mix.shell().info("Auto-admin is enabled: no sign-in needed in this environment.")
end
