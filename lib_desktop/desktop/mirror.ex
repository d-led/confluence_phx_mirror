defmodule ConfluencePhxMirror.Desktop.Mirror do
  @moduledoc """
  Copying a space into the local catalogue.

  This is the loop, not the transformation. Everything that turns a Confluence
  page into mirror content is the server's and is called unchanged:
  `Sync.page_attrs/1` maps a DTO as it always did, `Sync.Emoticons` and
  `Sync.Renderer` produce the HTML and its text, `Mirror.Page.slugify/1` builds
  the slug, `Mirror.attachment_ref/2`'s *shape* is honoured through the
  `:attachment_lookup` option the renderer already takes. What differs is only
  where the rows go, and that one process does the work — there is no queue to
  coordinate and no fleet to keep apart.

  Two passes over a space, because the second needs the first. Pages are written
  first so every page has an id; the id→page index is built from those rows; and
  only then is each body rendered. That way a link to a page that has not been
  read yet still becomes a local link rather than one back to Confluence.
  """

  import Ecto.Query

  alias ConfluencePhxMirror.Blobs.Store
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page, Space}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.{Emoticons, Renderer}

  @typedoc "Called after each page, so a screen can show the work moving."
  @type progress :: (done :: non_neg_integer(), total :: non_neg_integer() -> any())

  @doc """
  Mirrors one space, by key.

  Options: `:source` (defaults to the configured one) and `:on_page`, a
  `t:progress/0`.

  Answers `{:ok, %{space: space, pages: count}}` once every page has a body, or
  the first error, which stops the run rather than half-copying a space.
  """
  @spec mirror_space(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def mirror_space(space_key, opts \\ []) do
    source = Keyword.get(opts, :source, Source.source())
    on_page = Keyword.get(opts, :on_page, fn _done, _total -> :ok end)

    with {:ok, dto} <- find_space(source, space_key),
         {:ok, space} <- upsert_space(dto),
         # Recorded only once the source has confirmed the space exists. A key
         # nobody has — a typo, a space deleted upstream — used to be recorded
         # first and asked about afterwards, so a mistyped run left the workspace
         # configured for a space that is not there, and every later whole-site
         # sync honoured it.
         :ok <- record_choice(space_key, opts),
         {:ok, dtos} <- source.pages(space_key, []),
         {:ok, pages} <- write_listing(space, dtos),
         index = index_of(pages, space.key),
         :ok <- write_bodies(source, space, dtos, index, on_page) do
      {:ok, %{space: space, pages: length(dtos)}}
    end
  end

  # Picking one space is a decision about what this workspace mirrors, and the
  # choice is recorded where the site-wide sync reads it (`Sync.SpaceScope`):
  # otherwise "mirror this one space" and the overview's "Sync now" are two
  # different opinions, and the second one — with nothing named — means the whole
  # site. A bulk run is not that decision (`remember: false`): copying everything
  # the site lists used to add every one of those keys to the configuration, which
  # is how a workspace configured for one space ended up holding — and importing —
  # a hundred others.
  defp record_choice(space_key, opts) do
    if Keyword.get(opts, :remember, true) do
      _ = Sync.SpaceScope.add(space_key, ConfluencePhxMirror.Audit.system_actor())
    end

    :ok
  end

  @doc "Spaces the source offers, as the picker shows them."
  @spec spaces(keyword()) :: {:ok, [map()]} | {:error, term()}
  def spaces(opts \\ []) do
    Keyword.get(opts, :source, Source.source()).spaces([])
  end

  @doc "How many pages the catalogue holds, per space key."
  @spec page_counts() :: %{String.t() => non_neg_integer()}
  def page_counts do
    from(p in Page,
      join: s in assoc(p, :space),
      group_by: s.key,
      select: {s.key, count(p.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Whether the catalogue holds a page at all.

  The question the mirror screen asks before it writes one: a catalogue with
  content has a mirror worth building, and an empty one has nothing to say.
  """
  @spec pages?() :: boolean()
  def pages?, do: page_counts() |> Map.values() |> Enum.sum() > 0

  # ---------------------------------------------------------------------------
  # Pass one: the rows, so every page has an id
  # ---------------------------------------------------------------------------

  defp find_space(source, key) do
    with {:ok, spaces} <- source.spaces([]) do
      case Enum.find(spaces, &(&1.key == key)) do
        nil -> {:error, {:unknown_space, key}}
        dto -> {:ok, dto}
      end
    end
  end

  defp upsert_space(dto) do
    attrs = %{
      key: dto.key,
      name: dto.name,
      type: Map.get(dto, :type) || "global",
      description: Map.get(dto, :description),
      homepage_confluence_id: Map.get(dto, :homepage_id),
      external_url: Map.get(dto, :url),
      labels: Map.get(dto, :labels) || [],
      synced_at: now()
    }

    case Repo.get_by(Space, key: dto.key) do
      nil -> %Space{} |> Space.changeset(attrs) |> Repo.insert()
      space -> space |> Space.changeset(attrs) |> Repo.update()
    end
  end

  defp write_listing(space, dtos) do
    dtos
    |> Enum.reduce_while({:ok, %{}}, fn dto, {:ok, acc} ->
      case upsert_page(space, dto, %{}) do
        {:ok, page} -> {:cont, {:ok, Map.put(acc, dto.id, page)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A page's identity is Confluence's id within its space, so a re-run updates
  # rather than duplicates. `Sync.page_attrs/1` is the server's mapping, used
  # as-is; only the two things it does not carry — labels and the space — are
  # added here.
  defp upsert_page(space, dto, extra) do
    attrs =
      dto
      |> Sync.page_attrs()
      |> Map.put(:space_id, space.id)
      |> Map.put(:labels, Map.get(dto, :labels) || [])
      |> Map.merge(extra)

    case Repo.get_by(Page, space_id: space.id, confluence_id: dto.id) do
      nil -> %Page{} |> Page.changeset(attrs) |> Repo.insert()
      page -> page |> Page.changeset(attrs) |> Repo.update()
    end
  end

  # The shape `Mirror.page_index/0` produces, so the renderer cannot tell which
  # database built it.
  defp index_of(pages, space_key) do
    Map.new(pages, fn {confluence_id, page} ->
      {confluence_id,
       %{
         db_id: page.id,
         space_key: space_key,
         confluence_id: confluence_id,
         slug: page.slug
       }}
    end)
  end

  # ---------------------------------------------------------------------------
  # Pass two: bodies, attachments, comments
  # ---------------------------------------------------------------------------

  defp write_bodies(source, space, dtos, index, on_page) do
    total = length(dtos)

    dtos
    |> Enum.with_index(1)
    |> Enum.reduce_while(:ok, fn {dto, done}, :ok ->
      with {:ok, page} <- upsert_page(space, dto, rendered_body(dto, space, index)),
           {:ok, _attachments} <- write_attachments(source, space, dto, page),
           {:ok, _comments} <- write_comments(source, dto, page) do
        on_page.(done, total)
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rendered_body(dto, space, index) do
    context = %{
      space_key: space.key,
      base_url: site_origin(Map.get(dto, :url)),
      pages: index,
      attachments: %{},
      # The renderer resolves a filename the way the server does — through a
      # function, which is what lets this build answer from memory instead of a
      # query.
      attachment_lookup: fn _owner_id, _filename -> nil end
    }

    html =
      Emoticons.from_storage(Map.get(dto.body, :export_view), Map.get(dto.body, :storage))

    rendered = Renderer.render(html, context)

    %{body_export: rendered.html, body_text: rendered.text}
  end

  defp write_attachments(source, space, dto, page) do
    with {:ok, attachments} <- source.attachments(dto.id, []) do
      Enum.reduce_while(attachments, {:ok, []}, fn dto_attachment, {:ok, acc} ->
        case write_attachment(source, space, dto, page, dto_attachment) do
          {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  # Bytes before the row: a file with no row is an orphan to sweep, a row with
  # no file is a broken link the archive would serve.
  defp write_attachment(source, space, dto, page, dto_attachment) do
    key = blob_key(space, dto, dto_attachment)

    attrs = %{
      page_id: page.id,
      comment_id: Map.get(dto_attachment, :comment_id),
      confluence_id: to_string(dto_attachment.id),
      filename: dto_attachment.filename,
      media_type: Map.get(dto_attachment, :media_type) || "application/octet-stream",
      byte_size: Map.get(dto_attachment, :byte_size),
      version_number: Map.get(dto_attachment, :version) || 1,
      download_url: Map.get(dto_attachment, :download_url),
      blob_key: key,
      external_updated_at: Map.get(dto_attachment, :updated_at),
      synced_at: now()
    }

    with {:ok, bytes} <- source.attachment_data(dto_attachment, []),
         {:ok, _key} <- Store.put(key, bytes) do
      case Repo.get_by(Attachment, page_id: page.id, confluence_id: to_string(dto_attachment.id)) do
        nil -> %Attachment{} |> Attachment.changeset(attrs) |> Repo.insert()
        attachment -> attachment |> Attachment.changeset(attrs) |> Repo.update()
      end
    end
  end

  defp blob_key(space, page, attachment) do
    "spaces/#{space.key}/pages/#{page.id}/attachments/#{attachment.id}/#{attachment.filename}"
  end

  defp write_comments(source, dto, page) do
    with {:ok, comments} <- source.comments(dto.id, []),
         {:ok, written} <- write_comment_rows(comments, page) do
      resolve_parents(written, comments)
      {:ok, written}
    end
  end

  defp write_comment_rows(comments, page) do
    Enum.reduce_while(comments, {:ok, []}, fn dto_comment, {:ok, acc} ->
      case write_comment(dto_comment, page) do
        {:ok, comment} -> {:cont, {:ok, [comment | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A reply names its parent by Confluence's id, and `parent_id` is a foreign key
  # into this same table — so the parent has to exist before the reply can point
  # at it. The server settles this after writing the comments, and so does this;
  # a reply whose parent the source no longer carries stays at the top level
  # rather than pointing at nothing.
  defp resolve_parents(written, comments) do
    by_confluence_id = Map.new(written, &{&1.confluence_id, &1})
    parent_of = Map.new(comments, &{&1.id, Map.get(&1, :parent_id)})

    Enum.each(written, fn comment ->
      with parent_confluence_id when not is_nil(parent_confluence_id) <-
             Map.get(parent_of, comment.confluence_id),
           %Comment{} = parent <- Map.get(by_confluence_id, parent_confluence_id) do
        comment
        |> Ecto.Changeset.change(parent_id: parent.id)
        |> Repo.update!()
      end
    end)
  end

  defp write_comment(dto, page) do
    attrs = %{
      page_id: page.id,
      confluence_id: dto.id,
      author_name: Map.get(dto, :author),
      author_account_id: Map.get(dto, :author_account_id),
      body_export: Map.get(dto, :body_export),
      body_text: Renderer.plain_text(Map.get(dto, :body_export) || ""),
      external_url: Map.get(dto, :url),
      external_created_at: Map.get(dto, :created_at),
      external_updated_at: Map.get(dto, :updated_at),
      version_number: Map.get(dto, :version_number) || 1,
      synced_at: now()
    }

    case Repo.get_by(Comment, page_id: page.id, confluence_id: dto.id) do
      nil -> %Comment{} |> Comment.changeset(attrs) |> Repo.insert()
      comment -> comment |> Comment.changeset(attrs) |> Repo.update()
    end
  end

  # The server has this as a private helper. Copying three lines is cheaper than
  # making it public for one caller, and it is a URL origin, not a rule.
  defp site_origin(nil), do: nil

  defp site_origin(url) do
    uri = URI.parse(url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
