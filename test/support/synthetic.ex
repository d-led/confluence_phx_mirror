defmodule ConfluencePhxMirror.Synthetic do
  @moduledoc """
  A mirror full of generated content, written fast enough to measure.

  A snapshot sync of a million pages is an overnight job — one page at a time,
  with labels, properties, rendering, attachments and comments per page. The
  scale suite needs the *result* of that job, not the job: this module writes
  the rows `Sync` would have written, in batches, and assigns local ids itself
  so the tree is resolved at insert time instead of row by row afterwards.

  The documents come from `ConfluencePhxMirror.Confluence.SyntheticContent`, and
  the page rows come from `Sync.page_attrs/1` — the same mapping a real sync
  uses — so what the harness measures is the table shape a sync produces.

  Only the tables a page view reads are filled: spaces, pages, a sparse handful
  of attachments, comments and links (so those queries are not trivially empty).
  Everything is written inside the caller's sandbox transaction and rolled back
  with it.
  """

  alias ConfluencePhxMirror.Confluence.SyntheticContent
  alias ConfluencePhxMirror.Mirror.{Page, Space}
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sync
  alias ConfluencePhxMirror.Sync.Renderer

  # Postgres takes at most 65_535 parameters per statement and a page row is
  # about two dozen of them, so a batch stays under three thousand rows. The
  # round trips are cheap; the parameter limit is not negotiable.
  @batch_size 2_000

  @tables ~w(pages spaces attachments comments links page_properties page_labels labels
             page_restrictions space_permissions)

  @doc """
  Empties the mirror and fills it with generated content.

  Options are `ConfluencePhxMirror.Confluence.SyntheticContent.options/1`:
  `:spaces`, `:pages_per_space` and `:branching`.
  """
  def seed!(opts \\ []) do
    opts = SyntheticContent.options(opts)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    empty!()
    insert_spaces(opts, now)
    insert_pages(opts, now)
    insert_details(opts, now)
    analyze()

    %{spaces: opts[:spaces], pages: opts[:spaces] * opts[:pages_per_space]}
  end

  # Without statistics Postgres plans from defaults and the measurements say
  # more about the fixture than about the mirror.
  defp analyze do
    Repo.query!("ANALYZE pages")
    Repo.query!("ANALYZE spaces")
    Repo.query!("ANALYZE links")
  end

  defp empty! do
    Repo.query!("TRUNCATE #{Enum.join(@tables, ", ")} RESTART IDENTITY CASCADE")
  end

  defp insert_spaces(opts, now) do
    rows =
      for space <- SyntheticContent.spaces(opts) do
        %{
          id: SyntheticContent.space_index(space.key),
          key: space.key,
          name: space.name,
          type: space.type,
          description: space.description,
          homepage_confluence_id: space.homepage_id,
          external_url: space.url,
          synced_at: now,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Space, rows)
    Map.new(rows, &{&1.key, &1.id})
  end

  defp insert_pages(opts, now) do
    1..opts[:spaces]
    |> Enum.flat_map(&pages_of(&1, opts, now))
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(&Repo.insert_all("pages", &1))
  end

  defp pages_of(space_index, opts, now) do
    space = SyntheticContent.space(space_index, opts)
    {:ok, dtos} = SyntheticContent.pages(space.key, opts)

    Enum.map(dtos, fn dto ->
      page = %Page{labels: Enum.sort(dto.labels), author_name: dto.version.by.display_name}
      text = Renderer.plain_text(dto.body.export_view)

      dto
      |> Sync.page_attrs()
      |> Map.merge(%{
        id: local_id(space_index, opts[:pages_per_space], dto.id),
        space_id: space_index,
        parent_id: parent_local_id(space_index, opts, dto.parent_id),
        # `Mirror.replace_labels/2` stores the sorted, normalised set; the
        # fixture does the same so a benchmark compares like with like.
        labels: page.labels,
        body_export: dto.body.export_view,
        body_text: text,
        # The sync builds the searchable text from the body and the byline;
        # without it a fixture is only findable by title, which would make
        # full-text search look like it works when it does not.
        search_text: Sync.search_text(text, page, %Space{name: space.name, key: space.key}, []),
        inserted_at: now,
        updated_at: now
      })
    end)
  end

  # One contiguous range of local ids per space, counting from one, so a page's
  # parent can be named while the batch is built.
  defp local_id(space_index, pages_per_space, confluence_id) do
    page_index = confluence_id - SyntheticContent.page_id(space_index, 1) + 1
    (space_index - 1) * pages_per_space + page_index
  end

  defp parent_local_id(_space_index, _opts, nil), do: nil

  defp parent_local_id(space_index, opts, parent_confluence_id) do
    local_id(space_index, opts[:pages_per_space], parent_confluence_id)
  end

  # A page in a hundred carries an attachment, a comment and a link, so the
  # queries that read those tables are not measuring an empty result.
  defp insert_details(opts, now) do
    every = 100

    for space_index <- 1..opts[:spaces],
        page_index <- every..opts[:pages_per_space]//every do
      {space_index, page_index}
    end
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn chunk ->
      Repo.insert_all("attachments", Enum.map(chunk, &attachment_row(&1, opts, now)))
      Repo.insert_all("comments", Enum.map(chunk, &comment_row(&1, opts, now)))
      Repo.insert_all("links", Enum.map(chunk, &link_row(&1, opts, now)))
    end)
  end

  defp attachment_row({space_index, page_index}, opts, now) do
    page_id =
      local_id(space_index, opts[:pages_per_space], confluence_id(space_index, page_index))

    %{
      confluence_id: "att#{page_id}",
      page_id: page_id,
      filename: "report-#{page_index}.pdf",
      media_type: "application/pdf",
      byte_size: 1024 * 100,
      version_number: 1,
      download_url: "/download/attachments/#{page_id}/report-#{page_index}.pdf",
      synced_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp comment_row({space_index, page_index}, opts, now) do
    page_id =
      local_id(space_index, opts[:pages_per_space], confluence_id(space_index, page_index))

    %{
      confluence_id: page_id + 500_000_000,
      page_id: page_id,
      author_name: "Jane Doe",
      author_account_id: "557058:5b0f3f2a-1c1e-4d2f-9d8a-000000000001",
      body_export: "<p>Reviewed page #{page_index}.</p>",
      body_text: "Reviewed page #{page_index}.",
      external_created_at: now,
      synced_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp link_row({space_index, page_index}, opts, now) do
    source = local_id(space_index, opts[:pages_per_space], confluence_id(space_index, page_index))
    target_page = max(page_index - 1, 1)

    target =
      local_id(space_index, opts[:pages_per_space], confluence_id(space_index, target_page))

    %{
      source_page_id: source,
      target_page_id: target,
      target_confluence_id: confluence_id(space_index, target_page),
      href: "/spaces/#{SyntheticContent.space_key(space_index)}/pages/#{target_page}",
      kind: "internal",
      label: "Page #{target_page}",
      inserted_at: now,
      updated_at: now
    }
  end

  defp confluence_id(space_index, page_index),
    do: SyntheticContent.page_id(space_index, page_index)
end
