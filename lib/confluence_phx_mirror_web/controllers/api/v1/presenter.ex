defmodule ConfluencePhxMirrorWeb.Api.V1.Presenter do
  @moduledoc """
  JSON representations of mirrored content.

  Shapes follow the Confluence REST API (`results`, `start`, `limit`, `size`,
  `_links`, `body.storage`, `body.export_view`, `metadata.labels`) so existing
  Confluence clients can be pointed at the mirror. A `mirror` object adds
  provenance that Confluence does not have: the sync time and the original URL.
  """

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs
  alias ConfluencePhxMirrorWeb.Endpoint
  alias ConfluencePhxMirrorWeb.Time

  def space(space) do
    %{
      "id" => space.id,
      "key" => space.key,
      "name" => space.name,
      "type" => space.type,
      "status" => "current",
      "description" => %{"plain" => %{"value" => space.description}},
      "homepage" => homepage(space),
      "_links" => %{
        "webui" => URLs.space_path(space.key),
        "self" => Endpoint.url() <> "/api/v1/spaces/#{space.key}",
        "base" => Endpoint.url()
      },
      "mirror" => %{"syncedAt" => Time.iso(space.synced_at), "source" => space.external_url}
    }
  end

  defp homepage(%{homepage_confluence_id: nil}), do: nil

  defp homepage(%{homepage_confluence_id: id}) do
    case Mirror.find_page(id) do
      {:ok, page} -> %{"id" => to_string(page.confluence_id), "title" => page.title}
      _ -> %{"id" => to_string(id)}
    end
  end

  @doc "Full page representation, including both bodies."
  def page(page) do
    %{
      "id" => to_string(page.confluence_id),
      "type" => page.type,
      "status" => page.status,
      "title" => page.title,
      "space" => space_ref(page.space),
      "ancestors" => Enum.map(page.ancestors || [], &%{"id" => to_string(&1)}),
      "version" => version(page),
      "history" => %{
        "createdDate" => Time.iso(page.external_created_at),
        "lastUpdated" => %{"when" => Time.iso(page.external_updated_at), "by" => author(page)}
      },
      "body" => %{
        "storage" => %{"value" => page.body_storage, "representation" => "storage"},
        "export_view" => %{"value" => page.body_export, "representation" => "view"}
      },
      "metadata" => %{
        "labels" => %{
          "results" => Enum.map(page.labels, &%{"name" => &1, "prefix" => "global"}),
          "size" => length(page.labels)
        }
      },
      "_links" => %{
        "webui" => URLs.page_path(page.space.key, page.confluence_id, page.slug),
        "self" => Endpoint.url() <> "/api/v1/pages/#{page.confluence_id}",
        "base" => Endpoint.url(),
        "original" => page.external_url
      },
      "mirror" => %{
        "syncedAt" => Time.iso(page.synced_at),
        "version" => page.version_number,
        "source" => page.external_url
      }
    }
  end

  @doc "Page representation without bodies, for lists and search hits."
  def summary(page) do
    %{
      "id" => to_string(page.confluence_id),
      "type" => page.type,
      "status" => page.status,
      "title" => page.title,
      "space" => space_ref(page.space),
      "version" => version(page),
      "metadata" => %{"labels" => %{"results" => Enum.map(page.labels, &%{"name" => &1})}},
      "_links" => %{
        "webui" => URLs.page_path(page.space.key, page.confluence_id, page.slug),
        "self" => Endpoint.url() <> "/api/v1/pages/#{page.confluence_id}",
        "original" => page.external_url
      },
      "mirror" => %{"syncedAt" => Time.iso(page.synced_at)}
    }
  end

  def attachment(attachment) do
    %{
      "id" => to_string(attachment.confluence_id),
      "type" => "attachment",
      "status" => "current",
      "title" => attachment.filename,
      "version" => %{"number" => attachment.version_number},
      "extensions" => %{
        "mediaType" => attachment.media_type,
        "fileSize" => attachment.byte_size
      },
      "metadata" => %{"comment" => ""},
      "_links" => %{
        "download" =>
          URLs.attachment_path(
            attachment.page.space.key,
            attachment.page.confluence_id,
            attachment.confluence_id,
            attachment.filename
          ),
        "original" => attachment.download_url
      }
    }
  end

  def comment(comment) do
    %{
      "id" => to_string(comment.confluence_id),
      "type" => "comment",
      "status" => "current",
      "title" => "Re: comment #{comment.confluence_id}",
      "ancestors" =>
        if(comment.parent_id, do: [%{"id" => to_string(comment.parent_id)}], else: []),
      "history" => %{
        "createdDate" => Time.iso(comment.external_created_at),
        "createdBy" => %{"displayName" => comment.author_name}
      },
      "body" => %{"export_view" => %{"value" => comment.body_export, "representation" => "view"}},
      "_links" => %{"original" => comment.external_url}
    }
  end

  @doc """
  Confluence-style result envelope.

  `total` is nil when the source cannot count cheaply; `next` is then omitted.
  """
  def list(items, start: start, limit: limit, total: total, path: path) do
    next =
      if is_integer(total) and start + length(items) < total do
        query = URI.encode_query(%{"start" => start + length(items), "limit" => limit})
        Endpoint.url() <> path <> "?" <> query
      end

    %{
      "results" => items,
      "start" => start,
      "limit" => limit,
      "size" => length(items),
      "_links" =>
        %{"base" => Endpoint.url(), "self" => Endpoint.url() <> path}
        |> then(fn links -> if next, do: Map.put(links, "next", next), else: links end)
    }
  end

  defp space_ref(space) do
    %{"id" => space.id, "key" => space.key, "name" => space.name}
  end

  defp version(page) do
    %{
      "number" => page.version_number,
      "message" => page.version_message,
      "when" => Time.iso(page.external_updated_at),
      "by" => author(page)
    }
  end

  defp author(page) do
    %{"displayName" => page.author_name, "accountId" => page.author_account_id}
  end
end
