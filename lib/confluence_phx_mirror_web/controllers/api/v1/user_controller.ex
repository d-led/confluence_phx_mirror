defmodule ConfluencePhxMirrorWeb.Api.V1.UserController do
  @moduledoc """
  Accounts, made before their person arrives.

  An account can exist ahead of its first sign-in: an administrator knows the
  address Confluence will send somebody with, and wants it present — linked to a
  Confluence identity, put in a group, watched, given a role — before that
  person ever opens the mirror. The same door the users screen has, for scripts.

  Administrator-only: creating an account is an access decision, and the rows it
  writes are the ones admission is judged by. Creating one here leaves no
  `provisioned_at`, so a later sync never takes the account away.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.Scope

  @doc """
  `POST /api/v1/users`

  Body: `{"email": "person@example.com", "role": "member"}` — `role` is `member`
  unless an administrator says `admin`.
  """
  def create(conn, params) do
    with :ok <- authorize(conn) do
      attrs = %{email: params["email"], role: params["role"] || "member"}

      case Accounts.create_user(attrs, {:user, conn.assigns.current_user}) do
        {:ok, user} ->
          conn
          |> put_status(201)
          |> json(Map.put(user_json(user), "welcome", welcome(Accounts.welcome(user))))

        {:error, changeset} ->
          refusal(conn, changeset)
      end
    end
  end

  # Whether the person was told, said as it happened: a caller cannot see the
  # node's mail configuration, and `sent` would be a claim about a server it
  # does not know.
  defp welcome({:ok, :sent}), do: "sent"
  defp welcome({:ok, :not_configured}), do: "not_configured"
  defp welcome({:error, _reason}), do: "failed"

  defp authorize(conn) do
    if Scope.admin?(Scope.from_assigns(conn.assigns)) do
      :ok
    else
      error(conn, 403, "not_authorized", "Creating an account is an administrator's decision.")
    end
  end

  defp user_json(user) do
    %{
      "id" => user.id,
      "email" => user.email,
      "display_name" => user.display_name,
      "role" => user.role
    }
  end

  # The changeset is the only place that knows why an address was refused, so its
  # errors are said as they are: a caller fixing a script needs the field.
  defp refusal(conn, changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, text ->
          String.replace(text, "%{#{key}}", to_string(value))
        end)
      end)
      |> Map.new(fn {field, messages} -> {to_string(field), Enum.join(messages, ", ")} end)

    error(conn, 422, "invalid_user", "The account could not be created.", details)
  end

  defp error(conn, status, code, message, details \\ nil) do
    body = %{"error" => %{"code" => code, "message" => message}}

    conn
    |> put_status(status)
    |> json(if details, do: put_in(body, ["error", "details"], details), else: body)
  end
end
