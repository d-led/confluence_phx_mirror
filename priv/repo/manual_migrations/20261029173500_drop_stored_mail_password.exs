defmodule ConfluencePhxMirror.Repo.Migrations.DropStoredMailPassword do
  use Ecto.Migration

  # The settings screen used to offer the SMTP password as a field. It no longer
  # does — the mirror reads `SMTP_PASSWORD` from the deployment, so that a
  # secret never travels in a database backup — and the adapter ignores a stored
  # value in the same release.
  #
  # Any row left behind is therefore already dead, and this only takes the
  # secret out of the database and out of every backup taken from here on. It
  # deletes a row, which is why it is manual rather than a deploy migration.
  def up do
    execute("DELETE FROM settings WHERE key = 'mail.password'")
  end

  def down do
    # Nothing to restore: the value cannot be recovered, and the screen has no
    # way to accept a new one. A deployment that relied on it sets
    # `SMTP_PASSWORD` instead.
    :ok
  end
end
