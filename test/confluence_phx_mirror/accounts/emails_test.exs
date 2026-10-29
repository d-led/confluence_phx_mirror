defmodule ConfluencePhxMirror.Accounts.EmailsTest do
  @moduledoc """
  The mails that tell a person their account exists, and how to get in.

  These are read by somebody who has never seen the mirror, so what the message
  points at has to be pressable and named — a button labelled with an address
  asks a reader to trust a link the label does not explain.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Accounts.{Emails, User}

  test "a welcome with the mirror's address opens it by name, and shows the address under it" do
    html =
      Emails.welcome(user(), site: "Acme", url: "https://mirror.test")
      |> html()

    assert html =~ ">Open the mirror</a>"
    assert html =~ "https://mirror.test"
    refute html =~ "Open https://mirror.test"
  end

  test "a welcome with a sign-in link offers that link, and says it expires" do
    html =
      Emails.welcome(user(), site: "Acme", sign_in: "https://mirror.test/session/token/abc")
      |> html()

    assert html =~ "https://mirror.test/session/token/abc"
    assert html =~ "expires in 15 minutes"
  end

  defp html(email), do: IO.iodata_to_binary(email.html_body)

  defp user, do: %User{id: 1, email: "ada@example.com", display_name: "Ada Lovelace"}
end
