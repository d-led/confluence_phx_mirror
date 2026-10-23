defmodule ConfluencePhxMirror.Accounts do
  @moduledoc """
  Mirror-local reader accounts.

  There are no Confluence logins: readers sign in through a single-use magic
  link, or use an API token. In development and test an administrator is
  assumed (`MIRROR_AUTO_ADMIN`), so no login is needed at all.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Accounts.{Admins, ApiToken, LoginToken, TokenHash, User}
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Mailer
  alias ConfluencePhxMirror.Repo

  @doc "Minutes a magic link stays valid."
  def login_token_minutes do
    Application.get_env(:confluence_phx_mirror, :accounts, [])[:login_token_minutes] || 15
  end

  @api_token_bytes 32
  # How much of a token is stored in clear as the lookup key. Twelve base64
  # characters are 72 bits: enough that two tokens of one mirror do not share a
  # prefix, and no use to anybody holding only the row.
  @token_prefix_length 12

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.one(
      from u in User,
        where: fragment("lower(?) = ?", u.email, ^String.downcase(String.trim(email)))
    )
  end

  def list_users do
    Repo.all(from u in User, order_by: [asc: u.email])
  end

  @doc "Finds a user or creates one (used by magic-link sign-up and auto admin)."
  def ensure_user(email, attrs \\ %{}) do
    case get_user_by_email(email) do
      nil ->
        %User{}
        |> User.changeset(
          Map.merge(%{email: email, display_name: display_name_for(email)}, attrs)
        )
        |> Repo.insert()
        |> case do
          {:ok, user} ->
            Audit.log(Audit.system_actor(), User.audit_event_created(user))
            {:ok, user}

          {:error, changeset} ->
            {:error, changeset}
        end

      user ->
        {:ok, user}
    end
  end

  def ensure_user!(email, attrs \\ %{}) do
    case ensure_user(email, attrs) do
      {:ok, user} ->
        user

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  @doc "Creates a user explicitly (admin UI)."
  def create_user(attrs, actor) do
    with {:ok, user} <-
           %User{}
           |> User.changeset(attrs)
           |> Repo.insert() do
      Audit.log(actor, User.audit_event_created(user))
      {:ok, user}
    end
  end

  @doc """
  Changes the role of an account.

  Seeded administrators (`CM_ADMINS`) and the local bootstrap account keep
  their administration: demoting them would remove the only way back in.
  """
  def change_role(%User{} = user, role, actor) do
    previous = user.role

    if role != "admin" and Admins.protected?(user) do
      {:error, :protected_admin}
    else
      with {:ok, user} <- user |> User.changeset(%{role: role}) |> Repo.update() do
        Audit.log(actor, User.audit_event_role_changed(user, previous))
        {:ok, user}
      end
    end
  end

  @doc """
  Sets the Confluence groups a reader belongs to.

  Group membership is what grants space access and, for the configured admin
  groups, administration.
  """
  def update_groups(%User{} = user, groups, actor) when is_list(groups) do
    previous = user.groups || []

    groups =
      groups
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    with {:ok, user} <- user |> User.identity_changeset(%{groups: groups}) |> Repo.update() do
      Audit.log(actor, User.audit_event_groups_changed(user, previous))
      {:ok, user}
    end
  end

  @doc "The administrator assumed in development and test."
  def ensure_admin!(email \\ admin_email()) do
    user = ensure_user!(email, %{role: "admin"})

    result =
      if user.role == "admin" do
        {:ok, user}
      else
        change_role(user, "admin", {:system, "auto_admin"})
      end

    case result do
      {:ok, user} ->
        user

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  defp admin_email do
    Application.get_env(:confluence_phx_mirror, :auto_admin_email, "admin@localhost")
  end

  defp display_name_for(email) do
    email
    |> String.split("@")
    |> hd()
    |> String.replace(~r/[._-]+/, " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
    |> case do
      "" -> email
      name -> name
    end
  end

  # ---------------------------------------------------------------------------
  # Magic links
  # ---------------------------------------------------------------------------

  @doc """
  Sends a single-use sign-in link.

  Unknown addresses only receive a link when self sign-up is enabled; otherwise
  they get the same response, which avoids leaking which addresses exist.
  """
  def request_login(email) do
    email = User.normalise_email(email)

    with {:ok, user} <- login_user(email) do
      plain = random_token()

      {:ok, _token} =
        %LoginToken{}
        |> LoginToken.changeset(%{
          user_id: user.id,
          token_hash: hash(plain),
          expires_at: DateTime.add(now(), login_token_minutes(), :minute)
        })
        |> Repo.insert()

      Audit.log(Audit.system_actor(), User.audit_event_login_requested(user))

      user
      |> ConfluencePhxMirror.Accounts.Emails.login_link(magic_link_url(plain))
      |> Mailer.deliver()
      |> case do
        {:ok, _} -> {:ok, :sent}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp login_user(email) do
    case get_user_by_email(email) do
      nil ->
        # Seeded administrators (CM_ADMINS) can always sign in: otherwise a new
        # deployment would need self sign-up just to reach the admin screens.
        if Application.get_env(:confluence_phx_mirror, :self_signup, false) or
             Admins.seeded?(email) do
          ensure_user(email)
        else
          {:error, :unknown_email}
        end

      user ->
        {:ok, user}
    end
  end

  @doc "Consumes a magic link. Tokens are single-use and expire after 15 minutes."
  def consume_login(plain) when is_binary(plain) do
    now = now()

    case Repo.one(
           from t in LoginToken,
             where: t.token_hash == ^hash(plain) and is_nil(t.used_at),
             preload: [:user]
         ) do
      nil ->
        {:error, :invalid}

      %LoginToken{} = token ->
        if DateTime.compare(token.expires_at, now) == :lt do
          {:error, :expired}
        else
          sign_in(token, now)
        end
    end
  end

  defp sign_in(token, now) do
    Repo.transaction(fn ->
      {:ok, _} = token |> Ecto.Changeset.change(used_at: now) |> Repo.update()

      {:ok, user} =
        token.user
        |> Ecto.Changeset.change(last_sign_in_at: now)
        |> Repo.update()

      user
    end)
    |> case do
      {:ok, user} ->
        Audit.log({:user, user}, User.audit_event_signed_in(user))
        {:ok, user}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp magic_link_url(token) do
    ConfluencePhxMirrorWeb.Endpoint.url() <> "/session/" <> token
  end

  # ---------------------------------------------------------------------------
  # API tokens
  # ---------------------------------------------------------------------------

  @doc """
  Creates an API token. The plaintext is returned once and never stored — what
  is kept is an Argon2id digest under the policy in `TokenHash`.
  """
  def create_api_token(%User{} = user, name, actor) do
    plain = random_token()

    with {:ok, token} <-
           %ApiToken{}
           |> ApiToken.changeset(%{
             user_id: user.id,
             name: name,
             token_hash: TokenHash.hash(plain),
             token_prefix: prefix_of(plain)
           })
           |> Repo.insert() do
      Audit.log(actor, ApiToken.audit_event_created(token, user))

      {:ok, plain, token}
    end
  end

  def list_api_tokens(%User{id: user_id}) do
    Repo.all(from t in ApiToken, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at])
  end

  def revoke_api_token(%User{id: user_id}, token_id, actor) do
    case Repo.get_by(ApiToken, id: token_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      token ->
        {:ok, _} = Repo.delete(token)

        Audit.log(actor, ApiToken.audit_event_revoked(token))

        :ok
    end
  end

  @doc "Authenticates a bearer token."
  def authenticate_api_token(plain) when is_binary(plain) do
    now = now()
    query = from t in ApiToken, where: not is_nil(t.user_id), preload: [:user]

    with {:ok, token} <- find_token(plain, query) do
      if expired?(token, now) do
        {:error, :expired_token}
      else
        touch(token, now)
        {:ok, token.user}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Service tokens (no user, one scope)
  # ---------------------------------------------------------------------------

  @doc "Tokens that belong to an integration rather than to a reader."
  def list_service_tokens do
    Repo.all(
      from t in ApiToken,
        where: is_nil(t.user_id),
        order_by: [asc: t.name]
    )
  end

  @doc """
  Creates a service token. The plaintext is returned once and never stored —
  what is kept is an Argon2id digest under the policy in `TokenHash`.
  """
  def create_service_token(name, scope, actor) do
    plain = random_token()

    with {:ok, token} <-
           %ApiToken{}
           |> ApiToken.changeset(%{
             name: name,
             scope: scope,
             token_hash: TokenHash.hash(plain),
             token_prefix: prefix_of(plain)
           })
           |> Repo.insert() do
      Audit.log(actor, ApiToken.audit_event_service_created(token))

      {:ok, plain, token}
    end
  end

  def revoke_service_token(id, actor) do
    case Repo.one(from t in ApiToken, where: is_nil(t.user_id) and t.id == ^id) do
      nil ->
        {:error, :not_found}

      token ->
        {:ok, _} = Repo.delete(token)
        Audit.log(actor, ApiToken.audit_event_revoked(token))
        :ok
    end
  end

  @doc "Authenticates a service token that was issued for `scope`."
  def authenticate_service_token(plain, scope) when is_binary(plain) do
    now = now()

    query =
      from t in ApiToken,
        where: is_nil(t.user_id) and t.scope == ^scope

    with {:ok, token} <- find_token(plain, query) do
      if expired?(token, now) do
        {:error, :expired_token}
      else
        touch(token, now)
        {:ok, token}
      end
    end
  end

  defp touch(%ApiToken{} = token, now) do
    {:ok, _} = token |> Ecto.Changeset.change(last_used_at: now) |> Repo.update()
    :ok
  end

  @doc "Authenticates `email:token` basic credentials, for Confluence-style clients."
  def authenticate_basic(email, plain) do
    with %User{} = user <- get_user_by_email(email),
         {:ok, %User{id: id}} <- authenticate_api_token(plain) do
      if id == user.id, do: {:ok, user}, else: {:error, :invalid_token}
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp expired?(%ApiToken{expires_at: nil}, _now), do: false

  defp expired?(%ApiToken{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt

  # A digest is salted, so it cannot be looked up by equality: the prefix narrows
  # the table to the row that could match, and the token itself decides. A token
  # that verifies against a digest written under an older policy is re-written
  # here — that is what makes changing the algorithm a decision rather than a
  # migration of live credentials.
  defp find_token(plain, query) do
    query
    |> where([t], t.token_prefix == ^prefix_of(plain))
    |> Repo.all()
    |> Enum.find_value({:error, :invalid_token}, fn token ->
      case TokenHash.verify(plain, token.token_hash) do
        :error -> nil
        :current -> {:ok, token}
        :legacy -> {:ok, upgrade_digest(token, plain)}
      end
    end)
  end

  defp upgrade_digest(%ApiToken{} = token, plain) do
    {:ok, upgraded} =
      token
      |> Ecto.Changeset.change(token_hash: TokenHash.hash(plain))
      |> Repo.update()

    upgraded
  end

  defp prefix_of(plain), do: String.slice(plain, 0, @token_prefix_length)

  # A magic-link token lives for one sign-in and is looked up by digest, so it
  # keeps the fast hash: there is no stored digest to attack offline.
  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp random_token,
    do: :crypto.strong_rand_bytes(@api_token_bytes) |> Base.url_encode64(padding: false)
end
