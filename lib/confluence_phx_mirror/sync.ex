defmodule ConfluencePhxMirror.Sync do
  @moduledoc """
  The ingestion pipeline.

  A sync has three jobs:

    1. **upsert** spaces and pages (identity, metadata, storage format),
    2. **render** each page's `export_view`, rewrite links and extract labels,
       links and search text,
    3. **mirror attachments** into the blob store and comments into Postgres.

  Every run is recorded as a `SyncRun` and audited. A failing page does not
  abort the run; it is collected as a per-page error and the run ends
  `partial`, so one broken macro can never take the whole mirror down.
  """

  import Ecto.Query
  require Logger

  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page, Space}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirror.Sync.{DynamicContent, Log, PageProperties, Renderer, SyncRun}

  @type mode :: :snapshot | :incremental | :space | :page
  @type report :: {:ok, SyncRun.t()}

  # ---------------------------------------------------------------------------
  # Public entry points
  # ---------------------------------------------------------------------------

  @doc """
  Runs a sync and records it.

  Options:

    * `:confluence_id` – required for `:page`
    * `:space_key` – required for `:space`
    * `:since` – for `:incremental`, defaults to one sync interval ago
    * `:actor` – audit actor, defaults to the system
    * `:trigger` – why the run happened, in words: "the hourly schedule",
      "the admin dashboard, by jane@acme.com"
    * `:source` – upstream source module, defaults to the configured one
  """
  @spec run(mode(), keyword()) :: report()
  def run(mode, opts \\ []) do
    source = Keyword.get(opts, :source, Source.source())
    actor = Keyword.get(opts, :actor, {:system, "sync"})
    trigger = Keyword.get(opts, :trigger)
    # One mirror holds one site's content; never let a sync write across sites.
    Sites.verify!()
    run = start_run(source, mode, actor, trigger)

    Logger.info("sync started",
      sync_run_id: run.id,
      mode: mode_to_string(mode),
      source: source_label(source),
      trigger: trigger
    )

    Log.current_run(run.id)

    Log.add(:info, "started a #{mode} sync of #{source_label(source)}",
      sync_run_id: run.id,
      trigger: trigger
    )

    try do
      {stats, errors} = do_run(mode, source, opts)
      finish_run(run, stats, errors, actor, trigger)
    rescue
      error ->
        fail_run(run, Exception.message(error), trigger)

        Logger.error("sync failed",
          sync_run_id: run.id,
          mode: mode_to_string(mode),
          source: source_label(source),
          reason: Exception.message(error)
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        fail_run(run, Exception.format(kind, reason, __STACKTRACE__), trigger)

        Logger.error("sync failed",
          sync_run_id: run.id,
          mode: mode_to_string(mode),
          source: source_label(source),
          reason: Exception.format(kind, reason, __STACKTRACE__)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp source_label(source) do
    if function_exported?(source, :name, 0), do: source.name(), else: inspect(source)
  end

  # ---------------------------------------------------------------------------
  # Modes
  # ---------------------------------------------------------------------------

  defp do_run(:snapshot, source, opts) do
    case source.spaces(opts) do
      {:ok, space_dtos} ->
        {space_dtos, skipped} = importable_spaces(space_dtos)
        spaces = upsert_spaces(space_dtos)
        {spaces, permission_errors} = sync_space_permissions(source, spaces)

        {entries, counts, errors, deleted} = sync_pages_of(spaces, source, opts)
        resolve_trees(spaces)
        index = Mirror.page_index()

        {stats, detail_errors} = sync_details(source, entries, index, opts)
        {members, group_errors} = sync_groups(source, opts)

        stats =
          Map.merge(stats, %{
            "spaces" => length(spaces),
            "skipped_spaces" => skipped,
            "deleted" => deleted,
            "group_members" => members
          })
          |> Map.merge(page_counts(counts))

        {stats, errors ++ permission_errors ++ detail_errors ++ group_errors}

      {:error, reason} ->
        raise_source_error(:spaces, nil, reason)
    end
  end

  defp do_run(:space, source, opts) do
    space_key = Keyword.fetch!(opts, :space_key)

    with {:ok, space} <- ensure_space(source, space_key, opts) do
      {_spaces, permission_errors} = sync_space_permissions(source, [space])
      {entries, counts, errors, deleted} = sync_pages_of([space], source, opts)
      resolve_trees([space])
      index = Mirror.page_index()

      {stats, detail_errors} = sync_details(source, entries, index, opts)
      {members, group_errors} = sync_groups(source, opts)

      stats =
        Map.merge(stats, %{"spaces" => 1, "deleted" => deleted, "group_members" => members})
        |> Map.merge(page_counts(counts))

      {stats, errors ++ permission_errors ++ detail_errors ++ group_errors}
    end
  end

  defp do_run(:page, source, opts) do
    confluence_id = Keyword.fetch!(opts, :confluence_id)
    previous = Page |> Repo.get_by(confluence_id: confluence_id) |> light()

    with {:ok, dto} <- source.page(confluence_id, opts),
         {:ok, space} <- ensure_space(source, dto.space_key, opts),
         {:ok, entry} <- upsert_page_record(space, dto, previous, force: true) do
      resolve_trees([space])
      index = Mirror.page_index()
      {stats, errors} = sync_details(source, [entry], index, opts)
      {_spaces, permission_errors} = sync_space_permissions(source, [space])
      {members, group_errors} = sync_groups(source, opts)
      refresh_dynamic_pages()

      {Map.merge(stats, %{
         "spaces" => 1,
         "pages" => 1,
         "changed" => if(entry.change == :updated, do: 1, else: 0),
         "unchanged" => if(entry.change == :unchanged, do: 1, else: 0),
         "group_members" => members
       }), errors ++ permission_errors ++ group_errors}
    else
      {:error, reason} -> raise_source_error(:page, confluence_id, reason)
    end
  end

  defp do_run(:incremental, source, opts) do
    since = Keyword.get(opts, :since, default_since(source))

    case source.changed_since(since, opts) do
      {:ok, dtos} ->
        spaces = ensure_spaces_for(source, dtos, opts)
        {spaces, permission_errors} = sync_space_permissions(source, spaces)
        {entries, counts, errors} = upsert_entries(dtos, spaces)
        resolve_trees(spaces)
        index = Mirror.page_index()
        {stats, detail_errors} = sync_details(source, entries, index, opts)
        {members, group_errors} = sync_groups(source, opts)

        stats =
          Map.merge(stats, %{"spaces" => length(spaces), "group_members" => members})
          |> Map.merge(page_counts(counts))

        {stats, errors ++ permission_errors ++ detail_errors ++ group_errors}

      {:error, :not_supported} ->
        do_run(:snapshot, source, opts)

      {:error, reason} ->
        raise_source_error(:changed_since, since, reason)
    end
  end

  defp raise_source_error(scope, id, reason) do
    raise "Confluence #{scope} fetch failed#{if id, do: " for #{inspect(id)}"}: #{inspect(reason)}"
  end

  # Everyone has a personal space, and mirroring the sync account's own drafts
  # is rarely what an operator wants, so personal spaces are skipped unless the
  # deployment asks for them (`CM_SYNC_PERSONAL_SPACES=true`). Syncing one space
  # explicitly still works: the filter only applies to a whole-site snapshot.
  defp importable_spaces(space_dtos) do
    if personal_spaces?() do
      {space_dtos, 0}
    else
      personal = Enum.filter(space_dtos, &(&1[:type] == "personal"))
      {space_dtos -- personal, length(personal)}
    end
  end

  defp personal_spaces? do
    :confluence_phx_mirror
    |> Application.get_env(:sync, [])
    |> Keyword.get(:personal_spaces, false)
  end

  # ---------------------------------------------------------------------------
  # Spaces and pages
  # ---------------------------------------------------------------------------

  defp upsert_spaces(space_dtos) do
    Enum.map(space_dtos, fn dto ->
      {:ok, space} = Mirror.upsert_space(space_attrs(dto))
      space
    end)
  end

  defp space_attrs(dto) do
    %{
      key: dto.key,
      name: dto.name,
      type: dto[:type] || "global",
      description: dto[:description],
      homepage_confluence_id: dto[:homepage_id],
      external_url: dto[:url],
      synced_at: now()
    }
  end

  defp ensure_space(source, space_key, opts) do
    case source.spaces(opts) do
      {:ok, space_dtos} ->
        case Enum.find(space_dtos, &(&1.key == space_key)) do
          nil -> Mirror.upsert_space(%{key: space_key, name: space_key, type: "global"})
          dto -> Mirror.upsert_space(space_attrs(dto))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Who may read a space is mirrored when the source can read it. Confluence
  # Cloud cannot (space permissions are writes only), and that is not an error:
  # the space is simply open, exactly as it is for the sync account.
  defp sync_space_permissions(source, spaces) do
    Enum.map_reduce(spaces, [], fn space, errors ->
      case fetch_space_permissions(source, space) do
        {:ok, permissions} ->
          {:ok, _} = Mirror.replace_space_permissions(space, permissions)
          {space, errors}

        :unsupported ->
          {space, errors}

        {:error, reason} ->
          {space, [error("space", space.key, {:space_permissions, reason}) | errors]}
      end
    end)
  end

  defp fetch_space_permissions(source, space) do
    if function_exported?(source, :space_permissions, 2) do
      case source.space_permissions(space.key, []) do
        {:error, :not_supported} -> :unsupported
        other -> other
      end
    else
      :unsupported
    end
  end

  # Groups are how Confluence grants access, so the sync refreshes the
  # membership of every group it has to make decisions on: the ones the content
  # mentions, plus whatever grants administration. A source that cannot read
  # groups keeps the membership the mirror already has.
  defp sync_groups(source, opts) do
    if function_exported?(source, :group_members, 2) do
      groups_to_refresh()
      |> Enum.reduce({0, []}, &refresh_group(source, &1, &2, opts))
    else
      {0, []}
    end
  end

  defp groups_to_refresh do
    config_groups = for key <- Admins.admin_groups(), do: {key, key}
    Enum.uniq_by(Mirror.referenced_groups() ++ config_groups, &elem(&1, 1))
  end

  defp refresh_group(source, {name, _key}, {count, errors}, opts) do
    case source.group_members(name, opts) do
      {:ok, members} ->
        {:ok, stored} = Mirror.replace_group_members(name, members)
        {count + stored, errors}

      # The site simply has no such group; that is an empty membership, not a
      # failure a reader should see.
      {:error, :not_found} ->
        {:ok, _} = Mirror.replace_group_members(name, [])
        {count, errors}

      {:error, :not_supported} ->
        {count, errors}

      {:error, reason} ->
        {count, [error("group", name, reason) | errors]}
    end
  end

  defp ensure_spaces_for(source, dtos, opts) do
    keys = dtos |> Enum.map(& &1.space_key) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Enum.flat_map(keys, fn key ->
      case ensure_space(source, key, opts) do
        {:ok, space} -> [space]
        {:error, _} -> []
      end
    end)
  end

  defp sync_pages_of(spaces, source, opts) do
    Enum.reduce(spaces, {[], %{changed: 0, unchanged: 0}, [], 0}, fn space,
                                                                     {entries, counts, errors,
                                                                      deleted} ->
      case source.pages(space.key, opts) do
        {:ok, dtos} ->
          {upserted, space_counts, page_errors} = upsert_entries(dtos, [space])
          {deleted_count, guard_errors} = reconcile_deletions(space, dtos)

          if deleted_count > 0 do
            Audit.log(Audit.system_actor(), Space.audit_event_pages_deleted(space, deleted_count))
          end

          {entries ++ upserted, add_counts(counts, space_counts),
           errors ++ page_errors ++ guard_errors, deleted + deleted_count}

        {:error, reason} ->
          {entries, counts, [error("space", space.key, reason) | errors], deleted}
      end
    end)
  end

  defp add_counts(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  # `pages` is what the run saw; `changed` is what it had to look at. The gap is
  # the point of an incremental mirror, so it is reported, not hidden.
  defp page_counts(counts) do
    %{
      "pages" => counts.changed + counts.unchanged,
      "changed" => counts.changed,
      "unchanged" => counts.unchanged
    }
  end

  # A source that suddenly lists no pages for a space is far more likely to be
  # a permission or filtering problem than a mass deletion. Confluence export
  # tools guard against exactly this, so an empty listing never wipes a space.
  defp reconcile_deletions(space, [] = _dtos) do
    if Mirror.count_pages(space.id) > 0 do
      {0, [error("space", space.key, :empty_listing_kept_existing_pages)]}
    else
      {0, []}
    end
  end

  defp reconcile_deletions(space, dtos) do
    {Mirror.mark_missing_deleted(space, Enum.map(dtos, & &1.id)), []}
  end

  # A snapshot of a real site lists hundreds of thousands of pages, so the run
  # is built around not touching them: existing pages are loaded once as a light
  # index, unchanged pages cost one key lookup, and only pages that changed are
  # rendered and asked for their attachments and comments.
  defp upsert_entries(dtos, spaces) do
    by_key = Map.new(spaces, &{&1.key, &1})
    existing = existing_pages()

    {entries, counts, errors} =
      Enum.reduce(dtos, {[], %{changed: 0, unchanged: 0}, []}, fn dto,
                                                                  {entries, counts, errors} ->
        case Map.fetch(by_key, dto.space_key) do
          {:ok, space} ->
            case upsert_page_record(space, dto, Map.get(existing, dto.id)) do
              {:ok, :unchanged} ->
                {entries, Map.update!(counts, :unchanged, &(&1 + 1)), errors}

              {:ok, entry} ->
                {[entry | entries], Map.update!(counts, :changed, &(&1 + 1)), errors}

              {:error, reason} ->
                {entries, counts, [error("page", dto.id, reason) | errors]}
            end

          :error ->
            {entries, counts, [error("page", dto.id, {:unknown_space, dto.space_key}) | errors]}
        end
      end)

    {Enum.reverse(entries), counts, errors}
  end

  # Only the fields change detection needs: a page body can be megabytes, and
  # keeping 400k of them in memory to compare them would defeat the purpose.
  # Confluence bumps the version on every edit, which is the signal we need.
  defp existing_pages do
    from(p in Page,
      select: {p.confluence_id, p.version_number, p.title, p.type, not is_nil(p.body_export)}
    )
    |> Repo.all()
    |> Map.new(fn {id, version, title, type, rendered?} ->
      {id, light(version, title, type, rendered?)}
    end)
  end

  defp light(version, title, type, rendered?),
    do: %{version_number: version, title: title, type: type, rendered?: rendered?}

  defp light(%Page{} = page),
    do: light(page.version_number, page.title, page.type, not is_nil(page.body_export))

  defp light(nil), do: nil

  defp upsert_page_record(space, dto, previous, opts \\ []) do
    attrs = page_attrs(dto)
    force? = Keyword.get(opts, :force, false)

    case change_of(previous, attrs) do
      :unchanged when not force? ->
        {:ok, :unchanged}

      change ->
        with {:ok, page} <- Mirror.upsert_page(space, attrs),
             {:ok, page} <- Mirror.replace_labels(page, dto.labels) do
          # Labels and properties are stored before any page renders, so label
          # listings and property reports in a snapshot see the whole run.
          {:ok, _properties} =
            Mirror.replace_properties(page, PageProperties.parse(dto.body.storage))

          {:ok,
           %{
             space: space,
             dto: dto,
             page: page,
             change: change,
             previous_version: previous && previous.version_number
           }}
        end
    end
  end

  defp change_of(nil, _attrs), do: :created

  defp change_of(previous, attrs) do
    cond do
      previous.version_number != attrs.version_number -> :updated
      previous.title != attrs.title -> :updated
      previous.type != attrs.type -> :updated
      not previous.rendered? -> :updated
      true -> :unchanged
    end
  end

  # A page DTO as the row it becomes. Public so the scale fixture
  # (`ConfluencePhxMirror.Synthetic`) can write the same row without the
  # per-page pipeline; keeping one mapping is what stops a benchmark from
  # measuring a table shape no sync ever produces.
  @doc false
  def page_attrs(dto) do
    %{
      confluence_id: dto.id,
      type: dto.type,
      status: dto.status,
      title: dto.title,
      slug: Page.slugify(dto.title),
      author_name: dto.version.by.display_name,
      author_account_id: dto.version.by.account_id,
      body_storage: dto.body.storage,
      ancestors: dto.ancestors,
      version_number: dto.version.number,
      version_message: dto.version.message,
      external_url: dto.url,
      external_created_at: dto.created_at,
      external_updated_at: dto.updated_at,
      synced_at: now()
    }
  end

  defp resolve_trees(spaces) do
    Enum.each(Enum.uniq_by(spaces, & &1.id), &Mirror.resolve_parents/1)
  end

  # ---------------------------------------------------------------------------
  # Rendering, labels, links, attachments, comments
  # ---------------------------------------------------------------------------

  defp sync_details(source, entries, index, _opts) do
    initial =
      {%{
         "attachments" => 0,
         "attachments_downloaded" => 0,
         "comments" => 0,
         "links" => 0,
         "notifications" => 0
       }, []}

    entries
    |> Task.async_stream(&render_entry(source, &1, index),
      max_concurrency: concurrency(),
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce(initial, fn
      {:ok, {:ok, page_stats, entry_errors}}, {stats, errors} ->
        {merge_stats(stats, page_stats), errors ++ entry_errors}

      {:ok, {:error, reason, dto}}, {stats, errors} ->
        Log.add(:warn, "page failed: #{dto.title}", page: dto.id, reason: format_error(reason))
        {stats, [error("page", dto.id, reason) | errors]}

      {:exit, reason}, {stats, errors} ->
        {stats, [error("page", nil, {:exit, inspect(reason)}) | errors]}
    end)
  end

  # Detail work is network-bound (one attachments and one comments call per
  # changed page), so a handful run at once; the source's rate limiter still
  # paces the requests.
  defp concurrency do
    :confluence_phx_mirror
    |> Application.get_env(Source.source(), [])
    |> Keyword.get(:sync_concurrency, 4)
  end

  defp render_entry(source, %{space: space, dto: dto, page: page, change: change}, index) do
    {attachments, attachment_errors} = mirror_attachments(source, space, page)
    restriction_errors = mirror_page_restrictions(source, page)
    attachment_map = Map.new(attachments, &attachment_ref(space, page, &1))

    context = %{
      page: page,
      space_key: space.key,
      base_url: site_origin(dto.url),
      pages: index,
      attachments: attachment_map
    }

    rendered = Renderer.render(dto.body.export_view, context)

    with {:ok, page} <- store_rendered_page(page, rendered, space, attachments),
         {:ok, _} <- Mirror.replace_links(page, rendered.links),
         {:ok, comments} <- mirror_comments(source, page, context) do
      page = Map.put(page, :space, space)
      {notifications, notification_errors} = notify(change, page, space)
      audit_change(change, page, space, dto)

      {:ok,
       %{
         "attachments" => length(attachments),
         "attachments_downloaded" => Enum.count(attachments, & &1.downloaded?),
         "comments" => comments,
         "links" => length(rendered.links),
         "notifications" => notifications
       }, attachment_errors ++ restriction_errors ++ notification_errors}
    else
      {:error, reason} -> {:error, reason, dto}
    end
  end

  # A page's read restrictions decide access before its space does, so they are
  # synced per page; a source that cannot read them says nothing at all.
  defp mirror_page_restrictions(source, page) do
    case fetch_restrictions(source, page) do
      {:ok, restrictions} ->
        {:ok, _} = Mirror.replace_page_restrictions(page, restrictions)
        []

      :unsupported ->
        []

      {:error, reason} ->
        [error("page", page.confluence_id, {:restrictions, reason})]
    end
  end

  defp fetch_restrictions(source, page) do
    if function_exported?(source, :restrictions, 2) do
      source.restrictions(page.confluence_id, [])
    else
      :unsupported
    end
  end

  # Dynamic macros are resolved from the mirror, so the stored body and its
  # search text both contain what a reader actually sees.
  defp store_rendered_page(page, rendered, space, attachments) do
    export = DynamicContent.expand(rendered.html, %{space: space, page: page})
    text = Renderer.plain_text(export)

    Mirror.update_rendered(page, %{
      body_export: export,
      body_text: text,
      search_text: search_text(text, page, space, attachments),
      synced_at: now()
    })
  end

  # A page's labels or properties change what label listings and property
  # reports show. Expansion is idempotent (the marker stays in the body), so
  # every page carrying a marker is simply re-expanded in place.
  defp refresh_dynamic_pages do
    Enum.each(Mirror.pages_with_dynamic_content(), fn page ->
      export = DynamicContent.expand(page.body_export, %{space: page.space, page: page})
      text = Renderer.plain_text(export)

      Mirror.update_rendered(page, %{
        body_export: export,
        body_text: text,
        search_text: search_text(text, page, page.space, Mirror.attachments(page)),
        synced_at: now()
      })
    end)
  end

  defp notify(:unchanged, _page, _space), do: {0, []}

  defp notify(change, page, _space) do
    results = Notifications.page_changed(page, change)

    notification_errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(fn {:error, reason} -> error("notification", page.confluence_id, reason) end)

    {length(results) - length(notification_errors), notification_errors}
  rescue
    error -> {0, [error("notification", page.confluence_id, Exception.message(error))]}
  end

  # Text search covers every field a reader is likely to remember: body, labels,
  # author, space and attachment filenames. Title is weighted separately by the
  # generated tsvector column.
  #
  # Public so the scale fixture (`ConfluencePhxMirror.Synthetic`) can store the
  # same searchable text without going through the per-page pipeline; a fixture
  # whose pages were only findable by title would make full-text search look
  # like it worked.
  @doc false
  def search_text(body_text, page, space, attachments) do
    [
      body_text,
      Enum.join(page.labels, " "),
      page.author_name,
      space.name,
      space.key,
      Enum.map_join(attachments, " ", & &1.filename)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp attachment_ref(space, page, attachment) do
    {attachment.filename,
     %{
       confluence_id: attachment.confluence_id,
       page_confluence_id: page.confluence_id,
       space_key: space.key,
       filename: attachment.filename
     }}
  end

  defp mirror_attachments(source, space, page) do
    case source.attachments(page.confluence_id, []) do
      {:ok, attachment_dtos} ->
        {attachments, errors} =
          Enum.map_reduce(attachment_dtos, [], fn dto, errors ->
            case mirror_attachment(source, space, page, dto) do
              {:ok, attachment} -> {attachment, errors}
              {:error, reason} -> {nil, [error("attachment", dto.id, reason) | errors]}
            end
          end)

        {Enum.reject(attachments, &is_nil/1),
         errors ++ prune_attachments(page, Enum.map(attachment_dtos, &to_string(&1.id)))}

      {:error, reason} ->
        {[], [error("attachments", page.confluence_id, reason)]}
    end
  end

  # Attachments deleted in Confluence must disappear from the mirror too; the
  # blob is removed first so a failed delete leaves a row pointing at nothing
  # instead of an orphaned file.
  defp prune_attachments(page, kept_confluence_ids) do
    stale =
      Repo.all(
        from a in Attachment,
          where: a.page_id == ^page.id and a.confluence_id not in ^kept_confluence_ids
      )

    Enum.each(stale, fn attachment ->
      if attachment.blob_key, do: Store.delete(attachment.blob_key)
      {:ok, _} = Repo.delete(attachment)

      Log.add(:warn, "attachment pruned: #{attachment.filename}",
        attachment: attachment.confluence_id,
        page: page.confluence_id
      )
    end)

    []
  end

  defp mirror_attachment(source, space, page, dto) do
    # Confluence hands out numeric ids on older sites and "att164058" on newer
    # ones; the mirror stores the text form either way.
    confluence_id = to_string(dto.id)
    existing = Repo.get_by(Attachment, confluence_id: confluence_id)

    blob_key = Key.attachment(space.key, page.confluence_id, confluence_id, dto.filename)

    with {:ok, blob_key, downloaded?} <- ensure_blob(source, dto, existing, blob_key) do
      attrs = %{
        confluence_id: confluence_id,
        page_id: page.id,
        filename: dto.filename,
        media_type: dto.media_type,
        byte_size: dto.byte_size,
        version_number: dto.version,
        download_url: dto.download_url,
        blob_key: blob_key,
        sha256: sha256_of(blob_key),
        external_updated_at: dto.updated_at,
        synced_at: now()
      }

      attachment = existing || %Attachment{}

      attachment
      |> Attachment.changeset(attrs)
      |> Repo.insert_or_update()
      |> case do
        {:ok, attachment} ->
          Log.add(:debug, "attachment mirrored: #{dto.filename}",
            attachment: confluence_id,
            page: page.confluence_id,
            downloaded: downloaded?
          )

          {:ok, Map.put(attachment, :downloaded?, downloaded?)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp ensure_blob(source, dto, existing, blob_key) do
    current? =
      existing && existing.blob_key == blob_key && existing.version_number == dto.version &&
        Store.exists?(blob_key)

    if current? do
      {:ok, blob_key, false}
    else
      with {:ok, data} <- source.attachment_data(dto, []),
           {:ok, _key} <- Store.put(blob_key, data) do
        {:ok, blob_key, true}
      end
    end
  end

  defp sha256_of(nil), do: nil

  defp sha256_of(blob_key) do
    case Store.read(blob_key) do
      {:ok, data} -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  defp mirror_comments(source, page, context) do
    case source.comments(page.confluence_id, []) do
      {:ok, comments} ->
        ids = Enum.map(comments, & &1.id)

        Repo.transaction(fn ->
          Enum.each(comments, fn dto ->
            rendered = Renderer.render(dto.body_export, %{context | page: page})

            attrs = %{
              confluence_id: dto.id,
              page_id: page.id,
              author_name: dto.author,
              body_export: rendered.html,
              body_text: rendered.text,
              external_url: dto.url,
              external_created_at: dto.created_at,
              synced_at: now()
            }

            comment =
              Repo.get_by(Comment, confluence_id: dto.id) || %Comment{}

            {:ok, comment} =
              comment
              |> Comment.changeset(attrs)
              |> Repo.insert_or_update()

            resolve_comment_parent(comment, dto.parent_id)
          end)

          from(c in Comment,
            where: c.page_id == ^page.id and c.confluence_id not in ^ids
          )
          |> Repo.delete_all()
        end)

        {:ok, length(comments)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_comment_parent(_comment, nil), do: :ok

  defp resolve_comment_parent(comment, parent_confluence_id) do
    case Repo.get_by(Comment, confluence_id: parent_confluence_id) do
      nil -> :ok
      parent -> comment |> Ecto.Changeset.change(parent_id: parent.id) |> Repo.update()
    end
  end

  defp audit_change(:unchanged, _page, _space, _dto), do: :ok

  # One line per changed page: the audit log keeps the run, the live log keeps
  # the detail an operator greps for when a single page looks wrong.
  defp audit_change(change, page, space, _dto) do
    Log.add(:info, "page #{change}: #{page.title}",
      page: page.confluence_id,
      space: space.key,
      version: page.version_number
    )
  end

  defp merge_stats(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  # ---------------------------------------------------------------------------
  # Sync run bookkeeping
  # ---------------------------------------------------------------------------

  defp start_run(source, mode, actor, trigger) do
    {:ok, run} =
      %SyncRun{}
      |> SyncRun.changeset(%{
        source: source.name(),
        mode: mode_to_string(mode),
        status: "running",
        started_at: now(),
        stats: %{}
      })
      |> Repo.insert()

    Audit.log(
      actor,
      SyncRun.audit_event_started(run, mode, source.name(),
        site: Sites.url(),
        trigger: trigger
      )
    )

    run
  end

  defp finish_run(run, stats, errors, actor, trigger) do
    status = if errors == [], do: "succeeded", else: "partial"

    stats = Map.put(stats, "errors", normalize_errors(errors))

    {:ok, run} =
      run
      |> SyncRun.changeset(%{
        status: status,
        finished_at: now(),
        stats: stats,
        error: errors |> List.first() |> format_error()
      })
      |> Repo.update()

    Audit.log(actor, SyncRun.audit_event_finished(run, trigger: trigger))

    # The home page prints the mirror's totals; the reader who arrives after a
    # sync should not be the one who pays for the scans it made stale.
    ConfluencePhxMirror.Mirror.Counters.warm()

    Logger.info("sync finished",
      sync_run_id: run.id,
      mode: run.mode,
      source: run.source,
      status: status,
      pages: stats["pages"] || 0,
      attachments: stats["attachments"] || 0,
      errors: length(errors)
    )

    Log.add(
      if(errors == [], do: :info, else: :warn),
      "finished a #{run.mode} sync: #{stats["pages"] || 0} pages, " <>
        "#{stats["attachments"] || 0} attachments, #{length(errors)} errors",
      sync_run_id: run.id
    )

    Log.current_run(nil)

    {:ok, run}
  end

  defp fail_run(run, message, trigger) do
    {:ok, run} =
      run
      |> SyncRun.changeset(%{status: "failed", finished_at: now(), error: message})
      |> Repo.update()

    Log.add(:error, "sync failed: #{message}", sync_run_id: run.id, trigger: trigger)
    Log.current_run(nil)

    Audit.log(Audit.system_actor(), SyncRun.audit_event_failed(run, message, trigger: trigger))
  end

  defp normalize_errors(errors) do
    errors
    |> Enum.map(fn err ->
      %{"scope" => err.scope, "id" => err.id, "reason" => format_error(err.reason)}
    end)
  end

  defp error(scope, id, reason), do: %{scope: scope, id: id, reason: reason}

  defp format_error(nil), do: nil
  defp format_error(%{reason: reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp mode_to_string(:snapshot), do: "snapshot"
  defp mode_to_string(:incremental), do: "incremental"
  defp mode_to_string(:space), do: "incremental"
  defp mode_to_string(:page), do: "webhook"

  defp default_since(source) do
    interval =
      Application.get_env(:confluence_phx_mirror, source, [])
      |> Keyword.get(:sync_interval_seconds, 0)

    lookback = Application.get_env(:confluence_phx_mirror, :sync, [])[:lookback_seconds] || 3600
    DateTime.add(DateTime.utc_now(), -max(interval, lookback), :second)
  end

  defp site_origin(nil), do: nil

  defp site_origin(url) do
    uri = URI.parse(url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
