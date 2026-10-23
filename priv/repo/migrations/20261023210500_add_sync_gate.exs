defmodule ConfluencePhxMirror.Repo.Migrations.AddSyncGate do
  use Ecto.Migration

  # One row, one claim. A sync takes the row for as long as its lease holds and
  # renews it as it works; a node that dies stops renewing, and the row becomes
  # claimable again — which is how an abandoned run is recognised.
  def change do
    create table(:sync_gate, primary_key: false) do
      add :id, :boolean, primary_key: true, default: true
      add :owner, :string
      add :expires_at, :utc_datetime
    end

    execute("INSERT INTO sync_gate (id) VALUES (true)", "DELETE FROM sync_gate")

    create constraint(:sync_gate, :sync_gate_single_row, check: "id = true")
  end
end
