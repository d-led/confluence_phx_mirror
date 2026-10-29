defmodule ConfluencePhxMirror.Notifications.Email do
  @moduledoc """
  E-mail rendering for notifications.
  """

  import Swoosh.Email

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Notifications.Notification

  @doc """
  Everything that changed for one reader, in one message.

  One page or a hundred: a sync is one morning's work to the site and one
  message to the reader, which is the whole of what batching is for. Each page
  is a line with its space, its version and a link, so a reader can see what
  moved without opening fifty tabs.
  """
  def updates(%User{} = user, [%Notification{} | _] = notifications) do
    Swoosh.Email.new()
    |> from(from_address())
    |> to({User.display_name(user), user.email})
    |> subject(subject(notifications))
    |> text_body(Enum.map_join(notifications, "\n\n", & &1.body))
    |> html_body(updates_html(notifications))
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

  # One page keeps its own subject, because a reader watching two pages should
  # not have to read "1 page changed" to learn which one.
  defp subject([one]), do: one.subject

  defp subject(notifications) do
    "[Mirror] #{length(notifications)} pages you watch changed"
  end

  defp updates_html(notifications) do
    ConfluencePhxMirror.Mail.Layout.message(
      "Confluence Mirror",
      title(notifications),
      summary(notifications) <> Enum.map_join(notifications, "", &line/1),
      footer: "You are receiving this because you subscribed to updates in the mirror."
    )
  end

  defp title([one]), do: escape(one.subject)
  defp title(notifications), do: "#{length(notifications)} pages you watch changed"

  defp summary([one]) do
    "<p style=\"margin:0 0 6px;\">This page changed. Here is what changed.</p>" <>
      ConfluencePhxMirror.Mail.Layout.quote(escape(one.body))
  end

  defp summary(_many), do: "<p style=\"margin:0 0 10px;\">These changed while you were away.</p>"

  # A line per page: where it is, what version it is now, and the way in.
  defp line(notification) do
    page = page_of(notification)
    space = page && page.space
    where = (space && space.key) || "the mirror"
    version = page && page.version_number

    """
    <div style="margin:0 0 10px;padding:10px 12px;background:#f6fafe;border:1px solid #d7e6f7;border-radius:10px;">
      <p style="margin:0 0 2px;font-size:13px;font-weight:600;">
        <a href="#{href(notification)}" style="color:#0052cc;text-decoration:none;">#{escape(notification.subject)}</a>
      </p>
      <p style="margin:0;font-size:12px;color:#5a6b7d;">#{escape(where)}#{version_line(version)}</p>
    </div>
    """
  end

  defp version_line(nil), do: ""
  defp version_line(version), do: " · version #{version}"

  # A link has to survive leaving the building, so it is absolute where the
  # deployment knows its own address and the bare path where it does not.
  defp href(notification) do
    page = page_of(notification)

    case page && page.space do
      nil ->
        "#"

      space ->
        site_url() <>
          ConfluencePhxMirror.Mirror.URLs.page_path(
            space.key,
            page.confluence_id,
            page.slug
          )
    end
  end

  # A notification loaded without its page (a test, or a row whose page went)
  # is one this message cannot link; it still names what changed.
  defp page_of(%Notification{} = notification) do
    if Ecto.assoc_loaded?(notification.page), do: notification.page, else: nil
  end

  defp site_url do
    case ConfluencePhxMirror.Sites.url() do
      url when is_binary(url) -> String.trim_trailing(url, "/")
      _unknown -> ""
    end
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
