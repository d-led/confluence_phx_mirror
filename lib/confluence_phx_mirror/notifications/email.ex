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
    """
    <div style="font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; max-width: 560px;">
      <h2 style="margin: 0 0 8px;">#{escape(notification.subject)}</h2>
      <pre style="white-space: pre-wrap; background: #f6f8fa; padding: 12px; border-radius: 8px;">#{escape(notification.body)}</pre>
      <p style="color: #6b7280; font-size: 12px;">You are receiving this because you subscribed to updates in the mirror.</p>
    </div>
    """
  end

  defp digest_html(notifications) do
    items =
      Enum.map_join(notifications, "\n", fn notification ->
        "<li style=\"margin-bottom: 12px;\"><strong>#{escape(notification.subject)}</strong><pre style=\"white-space: pre-wrap; margin: 4px 0 0;\">#{escape(notification.body)}</pre></li>"
      end)

    """
    <div style="font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; max-width: 640px;">
      <h2>Your daily mirror digest</h2>
      <ul>#{items}</ul>
    </div>
    """
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
