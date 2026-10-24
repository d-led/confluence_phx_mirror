defmodule ConfluencePhxMirror.Repo.Migrations.AddIdentityAccountIdsToUsers do
  @moduledoc """
  One person, several Confluence identities.

  A person often holds two Atlassian accounts — a personal one and a guest or
  contractor one — and both can be named by the content and by the permissions.
  Until now a mirror account could stand for exactly one of them, so half of
  what that person may read was invisible to them.

  `identity_account_ids` holds the *further* identities an administrator has
  linked to this account; the identity the sign-in itself matched stays in
  `confluence_account_id`. What a reader may open is the union of all of them,
  which is why the list is on the user row and not in a join table: the
  permission rules read it per page, and a column keeps that a read of a row
  rather than a query per page.

  `confluence_account_id` is deliberately not migrated into the array: it
  answers a different question — which identity did this person sign in as —
  and the sync's reconciliation still keys on it.

  A unique index cannot say "no account id appears in two rows' arrays", so
  `Accounts.link_identity/3` refuses a second owner and a test holds it; the
  list only grows when an administrator links an identity by hand.

  No index on the column: it holds a handful of identities on a handful of rows,
  it is written only by that one admin action, and the query that reads it ("who
  stands for this identity?") is asked for one page of people. An index would be
  cost without a reader to pay for it.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :identity_account_ids, {:array, :string}, null: false, default: []
    end
  end
end
