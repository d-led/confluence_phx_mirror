defmodule ConfluencePhxMirror.Repo.Migrations.CreateMailSends do
  use Ecto.Migration

  # Every message the mirror hands to a provider, one row each.
  #
  # Two jobs at once. The rows are the day's allowance: a hosted relay sells a
  # number of messages a day — Brevo's free plan three hundred, most paid ones a
  # figure of the same shape — and refuses the rest, so a mirror that finds the
  # limit by being refused has already lost what it tried to send. Counting
  # first is the only way to spend the last message well.
  #
  # And a row is the identity of a message. A job that fails after the provider
  # took the mail is retried by Oban, and the row it already wrote is what stops
  # the reader from getting it twice: `dedup_key` is unique among the rows that
  # were not refused, so the second attempt finds the first one's key.
  #
  # The table is new, so the index costs nothing to build and nothing is locked.
  def change do
    create table(:mail_sends) do
      add :dedup_key, :string
      add :day, :date, null: false
      # pending -> sent, or pending -> failed. A failed row keeps the day's
      # allowance (the provider may well have counted it) but frees the key, so
      # a retry of the same message is a new attempt rather than a duplicate.
      add :state, :string, null: false, default: "pending"
      add :error, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:mail_sends, [:day])

    create unique_index(:mail_sends, [:dedup_key],
             where: "state <> 'failed'",
             name: :mail_sends_message_index
           )
  end
end
