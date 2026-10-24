defmodule ConfluencePhxMirror.Accounts.Admins do
  @moduledoc """
  Who may administer the mirror.

  Three sources, checked in this order:

    * the `admin` role on the account (set in the admin UI);
    * a group listed in `:admin_groups` (`CM_ADMIN_GROUPS`), so a mirrored
      Confluence group grants administration to every reader in it — the
      membership comes from the sync, not from what the reader types;
    * an e-mail listed in `:admins` — the seeded `CM_ADMINS` list. Seeding gives
      an operator a first administrator before the UI exists, and a seeded
      address may sign in even when self sign-up is closed.

  The rules live here rather than in the schema so the UI, the session plug and
  the LiveView hook all answer with the same function.
  """

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror

  @type source :: :role | :group | :seed | nil

  @doc "Whether the account may open the admin screens."
  @spec admin?(User.t() | nil) :: boolean()
  def admin?(nil), do: false
  def admin?(%User{} = user), do: source(user) != nil

  @doc "How the account is an administrator, or `nil` when it is not."
  @spec source(User.t() | nil) :: source()
  def source(nil), do: nil
  def source(%User{role: "admin"}), do: :role

  def source(%User{} = user) do
    cond do
      seeded?(user.email) -> :seed
      in_admin_group?(user) -> :group
      true -> nil
    end
  end

  @doc "Whether a Confluence admin group, as last synced, includes the account."
  @spec in_admin_group?(User.t()) :: boolean()
  def in_admin_group?(%User{} = user) do
    Mirror.member_of_any_group?(User.identity_keys(user), admin_groups())
  end

  @doc "Whether an e-mail is configured as an administrator (`CM_ADMINS`)."
  @spec seeded?(String.t() | nil) :: boolean()
  def seeded?(email) when is_binary(email), do: User.normalise_email(email) in admins()
  def seeded?(_email), do: false

  @doc """
  Whether the account cannot lose administration.

  Seeded administrators and the local bootstrap account (`admin@localhost` in
  dev/test) exist so a deployment always has a way in; the UI must not be able
  to lock everyone out by demoting them.
  """
  @spec protected?(User.t() | nil) :: boolean()
  def protected?(nil), do: false

  def protected?(%User{} = user) do
    seeded?(user.email) or User.normalise_email(user.email) == bootstrap_email()
  end

  @doc """
  The local bootstrap administrator's address, normalised.

  A deployment that configures nothing still needs one way in, so the default
  is part of the rule rather than of the lookup: `nil` (a key present with no
  value) means "use the default", not "protect nobody".
  """
  @spec bootstrap_email() :: String.t()
  def bootstrap_email do
    :confluence_phx_mirror
    |> Application.get_env(:auto_admin_email)
    |> Kernel.||("admin@localhost")
    |> User.normalise_email()
  end

  @doc "Seeded administrator e-mails, normalised."
  def admins do
    :confluence_phx_mirror
    |> Application.get_env(:admins, [])
    |> Enum.map(&User.normalise_email/1)
  end

  @doc "Group names that grant administration, lower-cased."
  def admin_groups do
    :confluence_phx_mirror
    |> Application.get_env(:admin_groups, [])
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
  end
end
