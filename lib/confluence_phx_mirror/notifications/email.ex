defmodule ConfluencePhxMirror.Notifications.Email do
  @moduledoc """
  E-mail rendering for notifications.
  """

  import Swoosh.Email

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mail.Layout
  alias ConfluencePhxMirror.Notifications.Notification

  @doc """
  Everything that changed for one reader, in one message.

  One page or a hundred: a sync is one morning's work to the site and one
  message to the reader, which is the whole of what batching is for. One page
  is shown in full, because it is the change and not a mention of one; a list
  is an entry per page with its space, its version and a link, so a reader can
  see what moved without opening fifty tabs.
  """
  def updates(%User{} = user, [%Notification{} | _] = notifications) do
    message(user, notifications,
      subject: subject(notifications),
      title: title(notifications),
      inner: updates_body(notifications),
      footer: "You are receiving this because you subscribed to updates in the mirror."
    )
  end

  @doc "Daily digest for one user."
  def digest(%User{} = user, [%Notification{} | _] = notifications) do
    message(user, notifications,
      subject: "[Mirror] #{length(notifications)} page updates",
      title: "Your daily digest",
      inner:
        "<p style=\"margin:0 0 10px;\">#{length(notifications)} pages you watch changed.</p>" <>
          Enum.map_join(notifications, "", &digest_entry/1),
      footer: "One message a day, at the hour the mirror is set to send it."
    )
  end

  defp message(user, notifications, opts) do
    Swoosh.Email.new()
    |> from(from_address())
    |> to({User.display_name(user), user.email})
    |> subject(Keyword.fetch!(opts, :subject))
    |> text_body(Enum.map_join(notifications, "\n\n", & &1.body))
    |> html_body(
      Layout.message(
        "Confluence Mirror",
        Keyword.fetch!(opts, :title),
        Keyword.fetch!(opts, :inner),
        footer: Keyword.fetch!(opts, :footer)
      )
    )
  end

  # One page keeps its own subject, because a reader watching two pages should
  # not have to read "1 page changed" to learn which one.
  defp subject([one]), do: one.subject

  defp subject(notifications) do
    "[Mirror] #{length(notifications)} pages you watch changed"
  end

  defp title([one]), do: escape(one.subject)
  defp title(notifications), do: "#{length(notifications)} pages you watch changed"

  # One page is not a list: where it lives, what changed in it, and the way in.
  defp updates_body([one]) do
    Layout.muted(meta(one)) <>
      Layout.quote(escape(one.body)) <>
      Layout.button("Open the page", href(one))
  end

  defp updates_body(notifications) do
    "<p style=\"margin:0 0 10px;\">These changed while you were away.</p>" <>
      Enum.map_join(notifications, "", &line/1)
  end

  # A line per page: what it is, where it is, which version it is now, and the
  # way in.
  defp line(notification) do
    Layout.card(escape(notification.subject), href(notification), meta(notification))
  end

  # The digest is read in one pass, so the change itself comes with the link
  # rather than behind it.
  defp digest_entry(notification) do
    Layout.card(
      escape(notification.subject),
      href(notification),
      meta(notification),
      escape(notification.body)
    )
  end

  # Where the page lives and which version it is now: the quiet line that makes
  # a list of titles answerable at a glance.
  defp meta(notification) do
    page = page_of(notification)
    space = page && page.space
    where = (space && space.key) || "the mirror"

    escape(where) <> version_line(page && page.version_number)
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
