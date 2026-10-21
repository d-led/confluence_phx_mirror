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

  alias ConfluencePhxMirror.Accounts.Admins
  alias ConfluencePhxMirror.Audit
  alias ConfluencePhxMirror.Blobs.{Key, Store}
  alias ConfluencePhxMirror.Confluence.Source
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.{Attachment, Comment, Page, Space}
  alias ConfluencePhxMirror.Notifications
  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Sites
  alias ConfluencePhxMirror.Sync.{DynamicContent, PageProperties, Renderer, SyncRun}

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
    * `:source` – upstream source module, defaults to the configured one
  """
  @spec run(mode(), keyword()) :: report()
  def run(mode, opts \\ []) do
    source = Keyword.get(opts, :source, Source.source())
    actor = Keyword.get(opts, :actor, {:system, "sync"})
    # One mirror holds one site's content; never let a sync write across sites.
    Sites.verify!()
    run = start_run(source, mode, actor)

    try do
      {stats, errors} = do_run(mode, source, opts)
      finish_run(run, stats, errors, actor)
    rescue
      error ->
        fail_run(run, Exception.message(error))
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        fail_run(run, Exception.format(kind, reason, __STACKTRACE__))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # ---------------------------------------------------------------------------
  # Modes
  # ---------------------------------------------------------------------------

  defp do_run(:snapshot, source, opts) do
    case source.spaces(opts) do
      {:ok, space_dtos} ->
        spaces = upsert_spaces(space_dtos)
        {spaces, permission_errors} = sync_space_permissions(source, spaces)

        {entries, errors, deleted} = sync_pages_of(spaces, source, opts)
        resolve_trees(spaces)
        index = Mirror.page_index()

        {stats, detail_errors} = sync_details(source, entries, index, opts)
        {members, group_errors} = sync_groups(source, opts)

        stats =
          Map.merge(stats, %{
            "spaces" => length(spaces),
            "deleted" => deleted,
            "group_members" => members
          })

        {stats, errors ++ permission_errors ++ detail_errors ++ group_errors}

      {:error, reason} ->
        raise_source_error(:spaces, nil, reason)
    end
  end

  defp do_run(:space, source, opts) do
    space_key = Keyword.fetch!(opts, :space_key)

    with {:ok, space} <- ensure_space(source, space_key, opts) do
      {_spaces, permission_errors} = sync_space_permissions(source, [space])
      {entries, errors, deleted} = sync_pages_of([space], source, opts)
      resolve_trees([space])
      index = Mirror.page_index()

      {stats, detail_errors} = sync_details(source, entries, index, opts)
      {members, group_errors} = sync_groups(source, opts)

      stats =
        Map.merge(stats, %{"spaces" => 1, "deleted" => deleted, "group_members" => members})

      {stats, errors ++ permission_errors ++ detail_errors ++ group_errors}
    end
  end

  defp do_run(:page, source, opts) do
    confluence_id = Keyword.fetch!(opts, :confluence_id)

    with {:ok, dto} <- source.page(confluence_id, opts),
         {:ok, space} <- ensure_space(source, dto.space_key, opts),
         {:ok, entry} <- upsert_page_record(space, dto) do
      resolve_trees([space])
      index = Mirror.page_index()
      {stats, errors} = sync_details(source, [entry], index, opts)
      {_spaces, permission_errors} = sync_space_permissions(source, [space])
      {members, group_errors} = sync_groups(source, opts)
      refresh_dynamic_pages()

      {Map.merge(stats, %{"spaces" => 1, "group_members" => members}),
       errors ++ permission_errors ++ group_errors}
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
        {entries, errors} = upsert_entries(dtos, spaces)
        resolve_trees(spaces)
        index = Mirror.page_index()
        {stats, detail_errors} = sync_details(source, entries, index, opts)
        {members, group_errors} = sync_groups(source, opts)

        stats = Map.merge(stats, %{"spaces" => length(spaces), "group_members" => members})

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
      source.space_permissions(space.key, [])
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
    Enum.reduce(spaces, {[], [], 0}, fn space, {entries, errors, deleted} ->
      case source.pages(space.key, opts) do
        {:ok, dtos} ->
          {upserted, page_errors} = upsert_entries(dtos, [space])
          {deleted_count, guard_errors} = reconcile_deletions(space, dtos)

          if deleted_count > 0 do
            Audit.log(Audit.system_actor(), Space.audit_event_pages_deleted(space, deleted_count))
          end

          {entries ++ upserted, errors ++ page_errors ++ guard_errors, deleted + deleted_count}

        {:error, reason} ->
          {entries, [error("space", space.key, reason) | errors], deleted}
      end
    end)
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

  defp upsert_entries(dtos, spaces) do
    by_key = Map.new(spaces, &{&1.key, &1})

    Enum.map_reduce(dtos, [], fn dto, errors ->
      case Map.fetch(by_key, dto.space_key) do
        {:ok, space} ->
          case upsert_page_record(space, dto) do
            {:ok, entry} -> {entry, errors}
            {:error, reason} -> {nil, [error("page", dto.id, reason) | errors]}
          end

        :error ->
          {nil, [error("page", dto.id, {:unknown_space, dto.space_key}) | errors]}
      end
    end)
    |> then(fn {entries, errors} -> {Enum.reject(entries, &is_nil/1), errors} end)
  end

  defp upsert_page_record(space, dto) do
    attrs = page_attrs(dto)
    previous = Repo.get_by(Page, confluence_id: dto.id)

    change =
      cond do
        is_nil(previous) -> :created
        previous.version_number != attrs.version_number -> :updated
        previous.body_storage != attrs.body_storage -> :updated
        previous.title != attrs.title -> :updated
        true -> :unchanged
      end

    with {:ok, page} <- Mirror.upsert_page(space, attrs),
         {:ok, page} <- Mirror.replace_labels(page, dto.labels) do
      # Labels and properties are stored before any page renders, so label
      # listings and property reports in a snapshot see the whole run.
      {:ok, _properties} = Mirror.replace_properties(page, PageProperties.parse(dto.body.storage))

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

  defp page_attrs(dto) do
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
      {%{"pages" => 0, "attachments" => 0, "comments" => 0, "links" => 0, "notifications" => 0},
       []}

    Enum.reduce(entries, initial, fn entry, {stats, errors} ->
      case render_entry(source, entry, index) do
        {:ok, page_stats, entry_errors} ->
          {merge_stats(stats, page_stats), errors ++ entry_errors}

        {:error, reason} ->
          {stats, [error("page", entry.dto.id, reason) | errors]}
      end
    end)
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
         "pages" => 1,
         "attachments" => length(attachments),
         "comments" => comments,
         "links" => length(rendered.links),
         "notifications" => notifications
       }, attachment_errors ++ restriction_errors ++ notification_errors}
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
    export = DynamicContent.expand(rendered.html, %{space: space})
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
      export = DynamicContent.expand(page.body_export, %{space: page.space})
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
  defp search_text(body_text, page, space, attachments) do
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
         errors ++ prune_attachments(page, Enum.map(attachment_dtos, & &1.id))}

      {:error, reason} ->
        {[], [error("attachments", page.confluence_id, reason)]}
    end
  end

  # Attachments deleted in Confluence must disappear from the mirror too; the
  # blob is removed first so a failed delete leaves a row pointing at nothing
  # (visible in the audit log) instead of an orphaned file.
  defp prune_attachments(page, kept_confluence_ids) do
    stale =
      Repo.all(
        from a in Attachment,
          where: a.page_id == ^page.id and a.confluence_id not in ^kept_confluence_ids
      )

    Enum.each(stale, fn attachment ->
      if attachment.blob_key, do: Store.delete(attachment.blob_key)
      {:ok, _} = Repo.delete(attachment)

      Audit.log(Audit.system_actor(), Attachment.audit_event_deleted(attachment, page))
    end)

    []
  end

  defp mirror_attachment(source, space, page, dto) do
    existing = Repo.get_by(Attachment, confluence_id: dto.id)

    blob_key = Key.attachment(space.key, page.confluence_id, dto.id, dto.filename)

    with {:ok, blob_key} <- ensure_blob(source, dto, existing, blob_key) do
      attrs = %{
        confluence_id: dto.id,
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
          Audit.log(
            Audit.system_actor(),
            Attachment.audit_event_mirrored(attachment, page)
          )

          {:ok, attachment}

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
      {:ok, blob_key}
    else
      with {:ok, data} <- source.attachment_data(dto, []),
           {:ok, _key} <- Store.put(blob_key, data) do
        {:ok, blob_key}
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

  defp audit_change(change, page, space, _dto) do
    entry =
      case change do
        :created -> Page.audit_event_created(page, space)
        :updated -> Page.audit_event_updated(page, space)
      end

    Audit.log(Audit.system_actor(), entry)
  end

  defp merge_stats(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  # ---------------------------------------------------------------------------
  # Sync run bookkeeping
  # ---------------------------------------------------------------------------

  defp start_run(source, mode, actor) do
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
      SyncRun.audit_event_started(run, mode, source.name())
    )

    run
  end

  defp finish_run(run, stats, errors, actor) do
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

    Audit.log(actor, SyncRun.audit_event_finished(run))
    {:ok, run}
  end

  defp fail_run(run, message) do
    {:ok, run} =
      run
      |> SyncRun.changeset(%{status: "failed", finished_at: now(), error: message})
      |> Repo.update()

    Audit.log(Audit.system_actor(), SyncRun.audit_event_failed(run, message))
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
