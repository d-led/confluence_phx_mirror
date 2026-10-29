defmodule ConfluencePhxMirror.Notifications.Email do
  @moduledoc """
  E-mail rendering for notifications.
  """

  import Swoosh.Email

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Notifications.Notification

  @doc "Instant notification for one changed page."
  def page_updated(%Notification{} = notification, %User{} = user) do
    Swoosh.Email.new()
    |> from(from_address())
    |> to({User.display_name(user), user.email})
    |> subject(notification.subject)
    |> text_body(notification.body)
    |> html_body(page_updated_html(notification))
  end

  @doc "Daily digest for one user."
  def digest(%User{} = user, [%Notification{} | _] = notifications) do
    Swoosh.Email.new()
    |> from(from_address())
    |> to({User.display_name(user), user.email})
    |> subject("[Mirror] #{length(notifications)} page updates")
    |> text_body(Enum.map_join(notifications, "\n\n", & &1.body))
    |> html_body(digest_html(notifications))
  end

  defp page_updated_html(notification) do
    ConfluencePhxMirror.Mail.Layout.message(
      "Confluence Mirror",
      escape(notification.subject),
      "<p style=\"margin:0;\">A page you watch has changed.</p>" <>
        ConfluencePhxMirror.Mail.Layout.quote(escape(notification.body)),
      footer: "You are receiving this because you subscribed to updates in the mirror."
    )
  end

  defp digest_html(notifications) do
    items =
      Enum.map_join(notifications, "\n", fn notification ->
        "<p style=\"margin:0 0 4px;font-weight:600;\">#{escape(notification.subject)}</p>" <>
          ConfluencePhxMirror.Mail.Layout.quote(escape(notification.body))
      end)

    ConfluencePhxMirror.Mail.Layout.message(
      "Confluence Mirror",
      "Your daily digest",
      "<p style=\"margin:0 0 6px;\">#{length(notifications)} pages you watch changed.</p>" <>
        items,
      footer: "One message a day, at the hour the mirror is set to send it."
    )
  end

  defp escape(text) do
    text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
  end

  defp from_address do
    {name, address} =
      Application.get_env(:confluence_phx_mirror, :notifications, [])
      |> Keyword.get(:from, {"Confluence Mirror", "mirror@localhost"})

    {name, address}
  end
end
