defmodule ConfluencePhxMirrorWeb.Api.V1.IdentityController do
  @moduledoc """
  The Confluence identities the mirror knows, and linking one to an account.

  A mirror is not a user directory: Confluence Cloud lists no site users, and it
  stopped answering "who is in this group". What the mirror does know is the
  people its content names — authors, ids in permissions — and those are the
  identities an administrator can stand an account on. One person often holds
  two Atlassian accounts, which is the whole reason linking exists: what the
  second identity may read becomes the account's too.

  Every call here is an administrator's, read or write. The list names account
  e-mails, and linking is an access decision (`Accounts.link_identity/3` refuses
  a caller who does not administer the mirror, whatever the screen decided).
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Mirror

  @default_limit 25
  @max_limit 100

  @doc """
  `GET /api/v1/identities?q=&limit=&offset=`

  A site can name a hundred thousand people, so this is a page of them, with
  the groups the last sync read and the account each one already stands for.
  """
  def index(conn, params) do
    with :ok <- authorize(conn) do
      limit = limit(params)
      offset = offset(params)
      query = params["q"]

      people = Mirror.people(limit: limit, offset: offset, query: query)
      accounts = Accounts.users_by_identity(Enum.map(people, & &1.account_id))

      json(conn, %{
        "items" => Enum.map(people, &identity_json(&1, Map.get(accounts, &1.account_id))),
        "total" => Mirror.count_people(query: query),
        "limit" => limit,
        "offset" => offset
      })
    end
  end

  @doc """
  `POST /api/v1/identities/{account_id}/link`

  Body: `{"user_id": 12}` or `{"email": "person@example.com"}` — the account that
  stands for this identity from now on.
  """
  def link(conn, %{"account_id" => account_id} = params) do
    with :ok <- authorize(conn),
         {:ok, user} <- account(conn, params) do
      case Accounts.link_identity(user, account_id, actor(conn)) do
        {:ok, user} ->
          json(conn, %{
            "identity" => linked_identity_json(account_id, user),
            "account" => account_json(user)
          })

        {:error, reason} ->
          refusal(conn, reason, account_id)
      end
    end
  end

  @doc """
  `DELETE /api/v1/identities/{account_id}/link`

  What the identity carries stops being the account's. The identity an account
  signs in with is not a link and cannot be taken away here.
  """
  def unlink(conn, %{"account_id" => account_id}) do
    with :ok <- authorize(conn) do
      case Accounts.accounts_linked_to(account_id) do
        [user | _] ->
          case Accounts.unlink_identity(user, account_id, actor(conn)) do
            {:ok, user} ->
              json(conn, %{
                "identity" => linked_identity_json(account_id, nil),
                "account" => account_json(user)
              })

            {:error, reason} ->
              refusal(conn, reason, account_id)
          end

        [] ->
          error(
            conn,
            404,
            "not_linked",
            "#{account_id} is not linked to an account here."
          )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Who is asking
  # ---------------------------------------------------------------------------

  defp authorize(conn) do
    if Scope.admin?(Scope.from_assigns(conn.assigns)) do
      :ok
    else
      error(conn, 403, "not_authorized", "Linking identities is an administrator's decision.")
    end
  end

  defp actor(conn), do: {:user, conn.assigns.current_user}

  # An identity is linked to the account the request names, so the two ways of
  # naming one are both accepted: the id this mirror's screens use, and the
  # e-mail an administrator has in front of them.
  defp account(conn, params) do
    user_id = params["user_id"] || params["userId"]

    cond do
      is_nil(user_id) and is_nil(params["email"]) ->
        error(conn, 422, "missing_account", "Name the account with user_id or email.")

      not is_nil(user_id) ->
        by_id(conn, user_id)

      true ->
        case Accounts.get_user_by_email(params["email"]) do
          nil -> error(conn, 404, "unknown_account", "No account here uses #{params["email"]}.")
          user -> {:ok, user}
        end
    end
  end

  defp by_id(conn, id) do
    case Integer.parse(to_string(id)) do
      {value, ""} ->
        case Accounts.get_user(value) do
          nil -> error(conn, 404, "unknown_account", "No account has id #{id}.")
          user -> {:ok, user}
        end

      _ ->
        error(conn, 422, "invalid_account_id", "user_id must be a number.")
    end
  end

  # ---------------------------------------------------------------------------
  # Refusals
  # ---------------------------------------------------------------------------

  defp refusal(conn, :blank, _account_id) do
    error(conn, 422, "missing_identity", "Which Confluence identity?")
  end

  defp refusal(conn, :already_linked, account_id) do
    error(conn, 409, "already_linked", "#{account_id} is already that account's.")
  end

  defp refusal(conn, {:linked_elsewhere, other}, account_id) do
    error(
      conn,
      409,
      "linked_elsewhere",
      "#{account_id} already stands for #{other.email}; one identity belongs to one account."
    )
  end

  defp refusal(conn, :unknown_identity, account_id) do
    error(
      conn,
      404,
      "unknown_identity",
      "The mirror has never seen #{account_id}. Run a sync, or check the account id."
    )
  end

  defp refusal(conn, :not_linked, account_id) do
    error(
      conn,
      409,
      "not_a_link",
      "#{account_id} is not a link: it is the identity the account signs in with, and that one stays."
    )
  end

  defp refusal(conn, :not_authorized, _account_id), do: authorize(conn)

  defp refusal(conn, _reason, _account_id) do
    error(conn, 422, "link_refused", "The mirror could not link that identity.")
  end

  # ---------------------------------------------------------------------------
  # What an identity looks like
  # ---------------------------------------------------------------------------

  defp identity_json(identity, user) do
    %{
      "accountId" => identity.account_id,
      "displayName" => identity.display_name,
      "groups" => identity.groups,
      "linkedTo" => user && account_json(user)
    }
  end

  defp linked_identity_json(account_id, user) do
    %{
      "accountId" => account_id,
      "groups" => Mirror.groups_of([account_id]),
      "linkedTo" => user && account_json(user)
    }
  end

  defp account_json(user) do
    %{
      "id" => user.id,
      "email" => user.email,
      "displayName" => user.display_name,
      "role" => user.role
    }
  end

  # ---------------------------------------------------------------------------
  # The window
  # ---------------------------------------------------------------------------

  defp limit(params) do
    params
    |> param("limit", @default_limit)
    |> min(@max_limit)
    |> max(1)
  end

  defp offset(params), do: params |> param("offset", 0) |> max(0)

  defp param(params, name, default) do
    case Integer.parse(to_string(params[name] || "")) do
      {value, ""} -> value
      _ -> default
    end
  end

  defp error(conn, status, code, message) do
    conn |> put_status(status) |> json(%{error: code, message: message})
  end
end
