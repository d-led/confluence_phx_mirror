defmodule ConfluencePhxMirror.Confluence.HttpSource do
  @moduledoc """
  Reads content from the Confluence Cloud REST API.

  Configuration (`config :confluence_phx_mirror, HttpSource` or environment):

    * `:base_url` – site URL, e.g. `https://acme.atlassian.net` or
      `https://acme.atlassian.net/wiki`
    * `:email` + `:api_token` – Atlassian API token credentials
      (`CM_ATL_EMAIL`, `CM_ATL_TOKEN`); a bearer token is used when no e-mail
      is configured
    * `:spaces` – `:all` or a list of space keys (`CM_SPACES=ENG,PROD`)
    * `:requests_per_second` / `:burst` – client-side rate limiting

  Every request is validated by `ConfluencePhxMirror.Confluence.SafeURL`
  (no redirects, same host only), rate limited, size capped and retried on
  transient errors. Content is fetched with `export_view` expanded, so the
  mirror gets Confluence's own macro rendering.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.RateLimiter
  alias ConfluencePhxMirror.Confluence.SafeURL

  @page_expand "body.storage,body.export_view,version,ancestors,metadata.labels,space,history"

  # Client sizing is deployment config (CM_HTTP_*), not a code constant.
  defp page_limit, do: config()[:page_size] || 50
  defp max_attempts, do: config()[:retries] || 3
  defp retry_backoff_ms, do: config()[:retry_backoff_ms] || 250

  # ---------------------------------------------------------------------------
  # Source behaviour
  # ---------------------------------------------------------------------------

  @impl true
  def name, do: "confluence-http"

  @impl true
  def kind, do: :live

  @impl true
  def spaces(_opts) do
    with {:ok, results} <-
           paginate_json("/space", %{"limit" => 100, "expand" => "description.plain,homepage"}) do
      {:ok, Enum.map(results, &parse_space/1)}
    end
  end

  @impl true
  def pages(space_key, _opts) do
    params = %{
      "spaceKey" => space_key,
      "type" => "page,blogpost",
      "status" => "current",
      "limit" => page_limit(),
      "expand" => @page_expand
    }

    with {:ok, results} <- paginate_json("/content", params) do
      {:ok, Enum.map(results, &parse_page(&1, space_key))}
    end
  end

  @impl true
  def page(confluence_id, _opts) do
    path = "/content/#{confluence_id}"

    with {:ok, body} <- request_json(path, %{"expand" => @page_expand}) do
      {:ok, parse_page(body, space_key_of(body))}
    end
  end

  @impl true
  def comments(confluence_id, _opts) do
    path = "/content/#{confluence_id}/child/comment"

    with {:ok, results} <-
           paginate_json(path, %{"limit" => 100, "expand" => "body.export_view,version,history"}) do
      {:ok, Enum.map(results, &parse_comment(&1, confluence_id))}
    end
  end

  @impl true
  def attachments(confluence_id, _opts) do
    path = "/content/#{confluence_id}/child/attachment"

    with {:ok, results} <- paginate_json(path, %{"limit" => 100, "expand" => "version,metadata"}) do
      {:ok, Enum.map(results, &parse_attachment(&1, confluence_id))}
    end
  end

  @impl true
  def restrictions(confluence_id, _opts) do
    with {:ok, body} <-
           request_json("/content/#{confluence_id}/restriction/byOperation/read", %{}) do
      {:ok, parse_restrictions(body)}
    end
  end

  @impl true
  def space_permissions(_space_key, _opts), do: {:error, :not_supported}

  @impl true
  def group_members(group_name, _opts) do
    path = "/group/#{URI.encode_www_form(group_name)}/member"

    with {:ok, results} <- paginate_json(path, %{"limit" => page_limit()}) do
      {:ok, Enum.map(results, &parse_group_member/1)}
    end
  end

  @impl true
  def attachment_data(attachment, _opts) do
    with {:ok, url} <- SafeURL.resolve(attachment.download_url, config()[:base_url]),
         {:ok, response} <- request(:get, url, []) do
      if response.status in 200..299 do
        {:ok, response.body}
      else
        {:error, {:http, response.status}}
      end
    end
  end

  @impl true
  def changed_since(since, _opts) do
    cql = ~s[lastmodified >= "#{format_cql_time(since)}" and type in (page, blogpost)]

    params = %{"cql" => cql, "limit" => page_limit(), "expand" => @page_expand}

    with {:ok, results} <- paginate_json("/content/search", params) do
      allowed = config()[:spaces]

      pages =
        results
        |> Enum.map(&parse_page(&1, space_key_of(&1)))
        |> Enum.filter(fn page -> allowed == :all or page.space_key in List.wrap(allowed) end)

      {:ok, pages}
    end
  end

  # ---------------------------------------------------------------------------
  # Diagnostics
  # ---------------------------------------------------------------------------

  @doc """
  Verifies the configured URL and credentials against Confluence.

  Used by `mix confluence.probe`; never called by the sync itself.
  """
  def probe do
    with {:ok, base_url} <- configured_base_url(),
         {:ok, body} <- request_json("/user/current", %{}) do
      {:ok,
       %{
         base_url: base_url,
         display_name: body["displayName"],
         email: body["email"],
         account_id: body["accountId"]
       }}
    end
  end

  defp configured_base_url do
    case config()[:base_url] do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :missing_base_url}
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc false
  def parse_space(content) do
    %{
      key: content["key"],
      name: content["name"],
      type: content["type"] || "global",
      description: get_in(content, ["description", "plain", "value"]),
      homepage_id: parse_id(get_in(content, ["homepage", "id"])),
      url: public_url(content["_links"]["webui"])
    }
  end

  @doc false
  def parse_restrictions(body) do
    restrictions = body["restrictions"] || %{}

    subjects(
      get_in(restrictions, ["user", "results"]) || [],
      "user",
      &(&1["email"] || &1["accountId"])
    ) ++
      subjects(
        get_in(restrictions, ["group", "results"]) || [],
        "group",
        &(&1["name"] || &1["id"])
      )
  end

  defp subjects(entries, subject_type, key_of) do
    for entry <- entries,
        key = key_of.(entry),
        is_binary(key),
        do: %{subject_type: subject_type, subject_key: key}
  end

  @doc false
  def parse_page(content, space_key) do
    ancestors = for ancestor <- content["ancestors"] || [], id = parse_id(ancestor["id"]), do: id

    %{
      id: parse_id(content["id"]),
      type: content["type"] || "page",
      status: content["status"] || "current",
      title: content["title"] || "Untitled",
      space_key: space_key,
      parent_id: List.last(ancestors),
      ancestors: ancestors,
      version: parse_version(content["version"]),
      body: %{
        storage: get_in(content, ["body", "storage", "value"]),
        export_view: get_in(content, ["body", "export_view", "value"])
      },
      labels: Enum.map(get_in(content, ["metadata", "labels", "results"]) || [], & &1["name"]),
      url: public_url(content["_links"]["webui"]),
      created_at: parse_time(content["history"] && content["history"]["createdDate"]),
      updated_at:
        parse_time(
          get_in(content, ["version", "when"]) ||
            (content["history"] && content["history"]["lastUpdated"])
        )
    }
  end

  defp parse_version(nil), do: %{number: 1, message: nil, when: nil, by: %{}}

  defp parse_version(version) do
    %{
      number: version["number"] || 1,
      message: version["message"],
      when: parse_time(version["when"]),
      by: %{
        display_name: get_in(version, ["by", "displayName"]),
        account_id: get_in(version, ["by", "accountId"])
      }
    }
  end

  defp parse_comment(content, page_id) do
    parent_id =
      content
      |> Map.get("ancestors", [])
      |> List.last()
      |> case do
        %{"id" => id} -> parse_id(id)
        _ -> nil
      end

    %{
      id: parse_id(content["id"]),
      page_id: page_id,
      parent_id: parent_id,
      author: get_in(content, ["version", "by", "displayName"]),
      body_export: get_in(content, ["body", "export_view", "value"]),
      created_at: parse_time(get_in(content, ["version", "when"])),
      url: public_url(content["_links"]["webui"])
    }
  end

  defp parse_attachment(content, page_id) do
    %{
      id: parse_id(content["id"]),
      page_id: page_id,
      filename: content["title"],
      media_type: get_in(content, ["extensions", "mediaType"]) || "application/octet-stream",
      byte_size: get_in(content, ["extensions", "fileSize"]),
      version: get_in(content, ["version", "number"]) || 1,
      download_url: content["_links"]["download"],
      updated_at: parse_time(get_in(content, ["version", "when"]))
    }
  end

  defp parse_group_member(member) do
    %{
      email: member["email"] || get_in(member, ["user", "email"]),
      account_id: member["accountId"] || get_in(member, ["user", "accountId"]),
      display_name: member["displayName"] || get_in(member, ["user", "displayName"])
    }
  end

  defp space_key_of(content) do
    cond do
      is_binary(get_in(content, ["space", "key"])) ->
        content["space"]["key"]

      is_binary(get_in(content, ["_expandable", "space"])) ->
        content["_expandable"]["space"] |> Path.basename()

      true ->
        nil
    end
  end

  defp parse_id(nil), do: nil
  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(id) when is_binary(id), do: String.to_integer(id)

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP
  # ---------------------------------------------------------------------------

  defp paginate_json(path, params), do: paginate(path, params, [])

  defp paginate(path, params, acc) do
    with {:ok, body} <- request_json(path, params) do
      results = body["results"] || []
      acc = acc ++ results

      case get_in(body, ["_links", "next"]) do
        next when is_binary(next) -> paginate(next, %{}, acc)
        _ -> {:ok, acc}
      end
    end
  end

  defp request_json(path, params) do
    with {:ok, url} <- build_url(path, params) do
      json_request(:get, url)
    end
  end

  @doc """
  Sends a JSON request to the configured site.

  Only `mix confluence.seed` writes to Confluence; the sync itself never calls
  this with anything but `:get`. Kept here so writes share the same
  authentication, rate limiting, retries and URL safety as reads.
  """
  @spec json(:get | :post | :put, String.t(), Enumerable.t() | map() | nil) ::
          {:ok, term()} | {:error, term()}
  def json(method, path, payload \\ nil) do
    with {:ok, url} <- build_url(path, %{}) do
      json_request(method, url, payload)
    end
  end

  defp json_request(method, url, payload \\ nil) do
    options = if payload, do: [json: payload], else: []

    with {:ok, response} <- request(method, url, options) do
      cond do
        response.status in 200..299 ->
          decode_json(response.body)

        response.status == 401 ->
          {:error, {:unauthorized, body_snippet(response.body)}}

        # Confluence answers 403 both for a wrong token and for a token whose
        # account cannot read the site, so the message has to name both.
        response.status == 403 ->
          {:error, {:forbidden, body_snippet(response.body)}}

        response.status == 404 ->
          {:error, :not_found}

        true ->
          {:error, {:http, response.status, body_snippet(response.body)}}
      end
    end
  end

  defp build_url(path, params) do
    url =
      if String.starts_with?(path, ["http://", "https://"]) do
        path
      else
        api_base() <> path
      end

    url = if params == %{}, do: url, else: url <> "?" <> URI.encode_query(params)
    SafeURL.resolve(url, config()[:base_url])
  end

  defp request(method, url, options, attempt \\ 1) do
    RateLimiter.acquire()

    defaults = [
      headers: auth_headers(),
      receive_timeout: config()[:request_timeout_ms] || 30_000,
      connect_options: [timeout: config()[:connect_timeout_ms] || 10_000],
      redirect: false,
      retry: false,
      decode_body: false
    ]

    # `:req_options` lets a deployment (or a test) supply transport options such
    # as a stubbed plug; anything set here wins over the defaults above.
    request = [method: method, url: url] ++ defaults ++ options ++ (config()[:req_options] || [])

    case Req.request(request) do
      {:ok, %Req.Response{} = response} ->
        if retryable?(response) and attempt < max_attempts() do
          backoff(attempt)
          request(method, url, options, attempt + 1)
        else
          check_size(response)
        end

      {:error, reason} ->
        if attempt < max_attempts() do
          backoff(attempt)
          request(method, url, options, attempt + 1)
        else
          {:error, {:transport, reason}}
        end
    end
  end

  defp check_size(%Req.Response{body: body} = response) when is_binary(body) do
    limit =
      if String.contains?(
           response.headers["content-type"] |> List.wrap() |> List.first() || "",
           "json"
         ) do
        config()[:max_json_bytes] || 10_000_000
      else
        config()[:max_attachment_bytes] || 100_000_000
      end

    if byte_size(body) > limit,
      do: {:error, {:body_too_large, byte_size(body), limit}},
      else: {:ok, response}
  end

  defp check_size(response), do: {:ok, response}

  defp retryable?(%Req.Response{status: status}), do: status == 429 or status >= 500

  defp backoff(attempt) do
    Process.sleep(retry_backoff_ms() * Integer.pow(2, attempt - 1))
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp body_snippet(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp body_snippet(_), do: ""

  defp auth_headers do
    config = config()

    cond do
      is_binary(config[:email]) and is_binary(config[:api_token]) ->
        [{"authorization", "Basic " <> Base.encode64("#{config[:email]}:#{config[:api_token]}")}]

      is_binary(config[:api_token]) ->
        [{"authorization", "Bearer " <> config[:api_token]}]

      true ->
        []
    end
  end

  defp api_base do
    base = (config()[:base_url] || "") |> String.trim_trailing("/")

    cond do
      String.ends_with?(base, "/rest/api") -> base
      String.ends_with?(base, "/wiki") -> base <> "/rest/api"
      base == "" -> "/rest/api"
      true -> base <> "/wiki/rest/api"
    end
  end

  defp public_url(nil), do: nil

  defp public_url(path) when is_binary(path) do
    base = (config()[:base_url] || "") |> String.trim_trailing("/")

    cond do
      String.starts_with?(path, ["http://", "https://"]) -> path
      String.starts_with?(path, "/wiki") -> origin(base) <> path
      base == "" -> path
      true -> base <> path
    end
  end

  defp origin(url) do
    uri = URI.parse(url)
    %{uri | path: nil, query: nil, fragment: nil} |> URI.to_string() |> String.trim_trailing("/")
  end

  defp format_cql_time(%DateTime{} = time) do
    time |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  defp config, do: Application.get_env(:confluence_phx_mirror, __MODULE__, [])
end
