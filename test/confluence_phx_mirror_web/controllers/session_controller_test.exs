defmodule ConfluencePhxMirrorWeb.SessionControllerTest do
  @moduledoc """
  What a reader gets when they open a sign-in link: a session, or the one
  sentence that says why not.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures
  import Swoosh.TestAssertions

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Accounts.LoginToken
  alias ConfluencePhxMirror.Repo
  alias Phoenix.Flash

  describe "a sign-in link" do
    test "signs the reader in and lands them on the mirror", %{conn: conn} do
      user = user_fixture(%{email: "reader@example.com"})
      link = link_for("reader@example.com")

      conn = get(conn, link)

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
      assert Flash.get(conn.assigns.flash, :info) =~ "Welcome"
    end

    test "works once: opening it again is not a second sign-in", %{conn: _conn} do
      user_fixture(%{email: "reader@example.com"})
      link = link_for("reader@example.com")

      get(build_conn(), link)

      conn = get(build_conn(), link)

      assert redirected_to(conn) == "/session"
      assert Flash.get(conn.assigns.flash, :error) =~ "not valid"
    end

    test "says a link has expired rather than that it is wrong", %{conn: conn} do
      user = user_fixture(%{email: "reader@example.com"})
      link = expired_link_for(user)

      conn = get(conn, link)

      assert redirected_to(conn) == "/session"
      assert Flash.get(conn.assigns.flash, :error) =~ "expired"
    end

    test "leaves a disabled account disabled", %{conn: conn} do
      user = user_fixture(%{email: "reader@example.com"})
      link = link_for("reader@example.com")
      Accounts.set_disabled(user, true, {:system, "a test"})

      conn = get(conn, link)

      assert redirected_to(conn) == "/session"
      assert Flash.get(conn.assigns.flash, :error) =~ "disabled"
    end
  end

  # The plaintext leaves the mirror only in the e-mail, so a test reads it the
  # way a reader does: from the message that was sent.
  defp link_for(email) do
    {:ok, :sent} = Accounts.request_login(email)

    assert_email_sent(fn mail ->
      [_, path] = Regex.run(~r{(/session/[A-Za-z0-9_-]+)}, mail.text_body)
      send(self(), {:link, path})
      true
    end)

    assert_received {:link, path}
    path
  end

  defp expired_link_for(user) do
    plain = "an-expired-link"

    %LoginToken{}
    |> LoginToken.changeset(%{
      user_id: user.id,
      token_hash: :crypto.hash(:sha256, plain) |> Base.encode16(case: :lower),
      expires_at: DateTime.add(DateTime.utc_now(), -1, :minute)
    })
    |> Repo.insert!()

    "/session/#{plain}"
  end
end
