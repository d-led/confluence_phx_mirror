defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.UserProfile do
  @moduledoc """
  *User profile*: one person, and the pages of theirs this page's readers may open.

      <div class="mirror-macro" data-macro="user-profile" data-user="557058:…"></div>

  Confluence resolves this in the reader's browser and leaves the macro
  unexpanded in `export_view`, so a page carrying it showed the unknown-macro
  widget. What the macro names is a Confluence account id — a typed parameter the
  storage carries as `<ri:user ri:account-id="…"/>` — and the mirror learns those
  from the bylines it has read. So the answer is a person and their pages, never a
  profile form the mirror has nothing to fill in.

  Two things it will not do: invent a person the mirror has never seen, and name a
  page the host's readers may not open. A person the site knows but whose pages are
  all out of reach is still a person, and the macro says why the list is empty
  rather than looking like somebody who wrote nothing.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    case attrs |> Map.get("user", "") |> String.trim() do
      "" -> [Nodes.empty("This macro names no person, so there is no profile to show.")]
      account -> profile(account, Attributes.int(attrs, "limit", 20, 1..100), context)
    end
  end

  defp profile(account, limit, context) do
    case context.source.authored(context.page, account, limit: limit) do
      {:ok, %{name: name, pages: []}} ->
        [
          Nodes.heading(name),
          Nodes.person_link(name, account),
          Nodes.empty("No page these readers may open is written by #{name}.")
        ]

      {:ok, %{name: name, pages: pages}} ->
        [Nodes.heading(name), Nodes.person_link(name, account), Nodes.page_list(pages)]

      :error ->
        [Nodes.notice("The person this macro names is not in the mirror, or not readable here.")]
    end
  end
end
