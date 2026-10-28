defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.Contributors do
  @moduledoc """
  *Contributors*: the people whose names are on the pages of a space.

      <div class="mirror-macro" data-macro="contributors" data-limit="10"></div>

  The mirror records one author per page — the person Confluence names on the
  latest version — so this is "who wrote the pages here", counted in pages, and
  not "everyone who ever edited each page". That is the whole of the data a sync
  can read without version history, and the list says so beside each name.

  Two things it will not do:

    * name somebody a reader of this page could not meet in the pages they may
      open — the port counts only pages readable alongside this one;
    * count half a space — past a few thousand pages it says the space is too
      large rather than give a number that is only partly true.

  A deployment that publishes no names (`CM_ANONYMIZE_CONTRIBUTORS`) has nothing
  to show here, and says so.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Publishing
  alias ConfluencePhxMirror.Sync.DynamicContent.{Attributes, Context, Nodes}

  @impl true
  def render(attrs, %Context{} = context) do
    if Publishing.anonymise_contributors?() do
      [Nodes.notice("This mirror does not publish its contributors.")]
    else
      list(context, space(attrs), Attributes.int(attrs, "limit", 10, 1..50))
    end
  end

  defp list(context, space, limit) do
    case context.source.contributors(context.page, space, limit: limit) do
      {:ok, []} ->
        [Nodes.empty("No page in this space names an author yet.")]

      {:ok, people} ->
        [Nodes.heading("Contributors"), Nodes.person_list(people)]

      {:error, :too_large} ->
        [Nodes.notice("This space is too large to count its contributors in one pass.")]
    end
  end

  defp space(attrs), do: Map.get(attrs, "space")
end
