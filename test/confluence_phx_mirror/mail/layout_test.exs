defmodule ConfluencePhxMirror.Mail.LayoutTest do
  @moduledoc """
  Every message the mirror sends shares one frame.

  Not a style guide: a message whose colours differ from the site's reads as a
  phishing attempt, and these are the mails that tell a reader their account
  exists or that a page they watch changed. The shared frame is also why a new
  message cannot arrive looking like it came from somewhere else.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Accounts.Emails
  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mail.Layout
  alias ConfluencePhxMirror.Notifications.Email
  alias ConfluencePhxMirror.Notifications.Notification

  test "every message the mirror sends wears the site's frame" do
    %{page: page, accent: accent} = Layout.colours()

    for {what, email} <- messages() do
      assert email.html_body =~ page, "#{what}: the light-blue page"
      assert email.html_body =~ accent, "#{what}: the accent"
      assert email.html_body =~ "Confluence Mirror", "#{what}: where it is from"
    end
  end

  test "the frame carries the title and the reason the message arrived" do
    html = Layout.message("Site", "A title", "<p>Body</p>", footer: "Because you subscribed.")

    assert html =~ "A title"
    assert html =~ "<p>Body</p>"
    assert html =~ "Because you subscribed."
  end

  defp messages do
    [
      sign_in: Emails.login_link(user(), "https://mirror.test/sign-in/token"),
      welcome: Emails.welcome(user(), site: "Acme", url: "https://mirror.test"),
      page_changed: Email.updates(user(), [notification("A page you watch changed")]),
      digest: Email.digest(user(), [notification("One"), notification("Two")])
    ]
  end

  defp user do
    %User{id: 1, email: "reader@example.com", display_name: "Ada Reader"}
  end

  defp notification(subject), do: %Notification{subject: subject, body: "The page changed."}
end
