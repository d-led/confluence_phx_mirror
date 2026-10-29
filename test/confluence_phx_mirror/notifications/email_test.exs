defmodule ConfluencePhxMirror.Notifications.EmailTest do
  @moduledoc """
  What a reader can do with the message about a change: open the page it is
  about, and see what moved without opening fifty tabs.

  A notification's own words are the change itself, so these are about where
  those words go — one page in full, a burst as a list of pages, and a digest
  that says what changed *and* offers the link.
  """

  use ConfluencePhxMirror.DataCase, async: true

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mirror.{Page, Space}
  alias ConfluencePhxMirror.Notifications.{Email, Notification}

  test "one page is shown in full, under where it lives, with the way in" do
    html =
      Email.updates(reader(), [changed("Deploying the mirror", "The rollback section changed.")])
      |> html()

    assert html =~ "The rollback section changed."
    assert html =~ "PLAT · version 12"
    assert html =~ "/spaces/PLAT/pages/10001/deploying-the-mirror"
    assert html =~ "Open the page"
  end

  test "a burst is one entry per page, and the reasons wait on the page" do
    html =
      Email.updates(reader(), [
        changed("Release checklist", "Two boxes were added.", 1),
        changed("On-call rotation", "The winter rotation is published.", 2)
      ])
      |> html()

    assert html =~ "2 pages you watch changed"
    assert html =~ "Release checklist"
    assert html =~ "On-call rotation"
    refute html =~ "Two boxes were added.", "a hundred changes is not a hundred paragraphs"
  end

  test "the digest says what changed in each page and links it" do
    html =
      Email.digest(reader(), [changed("Release checklist", "Two boxes were added.")]) |> html()

    assert html =~ "Two boxes were added."
    assert html =~ "/spaces/PLAT/pages/10001/release-checklist"
  end

  defp html(email), do: IO.iodata_to_binary(email.html_body)

  defp reader, do: %User{id: 7, email: "ada@example.com", display_name: "Ada Lovelace"}

  defp changed(title, body, id \\ 1) do
    page = %Page{
      id: id,
      confluence_id: 10_000 + id,
      title: title,
      slug: slug(title),
      version_number: 12,
      space: %Space{id: 1, key: "PLAT", name: "Platform"}
    }

    %Notification{subject: "#{title} was updated", body: body, page: page}
  end

  defp slug(title), do: title |> String.downcase() |> String.replace(" ", "-")
end
