defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.ProfilePicture do
  @moduledoc """
  *Profile picture*: one person's face, and the way to their page here.

      <ac:structured-macro ac:name="profile-picture" ac:schema-version="1">
        <ac:parameter ac:name="user">
          <ri:user ri:account-id="557058:…"/>
        </ac:parameter>
      </ac:structured-macro>

  `export_view` carries a placeholder for this macro, so the mirror resolves it
  from what it has: the picture `Sync` stored for that account
  (`/people/:account_id/avatar`, which answers `404` when the mirror has none)
  and the person's page.

  A reader who may not be shown names gets neither. The picture route is closed
  to a stranger — a face is a name spelled in pixels — and this body is rendered
  once for every reader, so the safe shape is the stored one.

  With no picture on file the browser draws a broken image; the link beside it
  still goes somewhere, and `alt` says what the picture would have been.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    account = account(attrs)

    cond do
      not Publishing.identities_in_space?(context.space.key) ->
        [Nodes.notice("This mirror does not publish its contributors.")]

      account == "" ->
        [Nodes.empty("This macro names no person, so there is no picture to show.")]

      true ->
        [picture(account)]
    end
  end

  defp account(attrs), do: attrs |> Map.get("user", "") |> String.trim()

  defp picture(account) do
    {"a", [{"href", URLs.person_path(account)}, {"class", "mirror-profile-picture"}],
     [
       {"img",
        [
          {"src", URLs.person_path(account) <> "/avatar"},
          {"alt", "Profile picture"},
          {"class", "mirror-avatar"},
          {"loading", "lazy"}
        ], []}
     ]}
  end
end
