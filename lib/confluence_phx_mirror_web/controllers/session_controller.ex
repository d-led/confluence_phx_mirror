defmodule ConfluencePhxMirrorWeb.SessionController do
  @moduledoc """
  Passwordless sign-in: request a magic link, consume it, sign out.
  """

  use ConfluencePhxMirrorWeb, :controller

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Audit

  def new(conn, _params) do
    render(conn, :new,
      page_title: "Sign in",
      form: to_form(%{"email" => ""}, as: :user),
      auto_admin: Application.get_env(:confluence_phx_mirror, :auto_admin, false)
    )
  end

  def create(conn, %{"user" => %{"email" => email}}) do
    case Accounts.request_login(email) do
      {:ok, :sent} ->
        conn
        |> put_flash(:info, "If that address has access, a sign-in link is on its way.")
        |> redirect(to: ~p"/")

      {:error, :unknown_email} ->
        conn
        |> put_flash(:info, "If that address has access, a sign-in link is on its way.")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not send the sign-in e-mail: #{inspect(reason)}")
        |> put_status(:bad_gateway)
        |> render(:new,
          page_title: "Sign in",
          form: to_form(%{"email" => email}, as: :user),
          auto_admin: Application.get_env(:confluence_phx_mirror, :auto_admin, false)
        )
    end
  end

  def confirm(conn, %{"token" => token}) do
    case Accounts.consume_login(token) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Welcome, #{ConfluencePhxMirror.Accounts.User.display_name(user)}.")
        |> redirect(to: ~p"/")

      {:error, :expired} ->
        conn
        |> put_flash(:error, "That link has expired. Request a new one.")
        |> redirect(to: ~p"/session")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "That link is not valid. Request a new one.")
        |> redirect(to: ~p"/session")
    end
  end

  def delete(conn, _params) do
    if user = conn.assigns[:current_user] do
      Audit.user(user, "user.signed_out", "user", user.id)
    end

    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/")
  end
end
