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

  Every attempt is also one line in the sync log (`/admin/sync-log`) and one
  tick in `Traffic`: method, path, status, size and latency on success, the
  reason and the wait before a retry, and the failure that ended it. That is
  the detail; `Traffic.describe/1` is the account a run ends with.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.{RateLimiter, SafeURL, Traffic}
  alias ConfluencePhxMirror.Sync.Log

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
  def web_url, do: web_base()

  @impl true
  def spaces(_opts) do
    with {:ok, results} <-
           paginate_json("/space", %{"limit" => 100, "expand" => "description.plain,homepage"}) do
      {:ok, Enum.map(results, &parse_space/1)}
    end
  end

  @impl true
  def pages(space_key, _opts) do
    # Confluence Cloud does not filter on a comma-separated type list (`type=page,
    # blogpost` silently returns nothing), so ask for one content type at a time.
    with {:ok, pages} <- paginate_json("/content", content_params(space_key, "page")),
         {:ok, posts} <- paginate_json("/content", content_params(space_key, "blogpost")) do
      {:ok, Enum.map(pages ++ posts, &parse_page(&1, space_key))}
    end
  end

  defp content_params(space_key, type) do
    %{
      "spaceKey" => space_key,
      "type" => type,
      "status" => "current",
      "limit" => page_limit(),
      "expand" => @page_expand
    }
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
    with {:ok, url} <- download_url(attachment.download_url) do
      download(url)
    end
  end

  # Attachment bytes live behind a redirect on Confluence Cloud (the media API),
  # so the download is followed by hand: every hop has to stay on the site or on
  # an explicitly allowed Atlassian host.
  defp download(url, attempt \\ 1) do
    with {:ok, response} <- request(:get, url, []) do
      cond do
        response.status in 200..299 ->
          {:ok, response.body}

        response.status in [301, 302, 303, 307, 308] and attempt < 4 ->
          with {:ok, next} <- redirect_target(response, url), do: download(next, attempt + 1)

        true ->
          {:error, {:http, response.status}}
      end
    end
  end

  defp redirect_target(response, current) do
    with [location | _] <- List.wrap(response.headers["location"]),
         target = current |> URI.merge(location) |> URI.to_string(),
         true <- download_host?(target) do
      {:ok, target}
    else
      _ -> {:error, {:redirect_not_allowed, response.headers["location"]}}
    end
  end

  defp download_host?(url) do
    host = url |> URI.parse() |> Map.get(:host) || ""
    site = config()[:base_url] |> URI.parse() |> Map.get(:host)
    allowed = [site | List.wrap(config()[:download_hosts] || default_download_hosts())]

    Enum.any?(allowed, fn suffix -> is_binary(suffix) and suffix != "" and host == suffix end) or
      Enum.any?(allowed, fn suffix ->
        is_binary(suffix) and host != "" and String.ends_with?(host, "." <> suffix)
      end)
  end

  # The media API sits on these domains; a deployment can narrow or extend it
  # with `:download_hosts`.
  defp default_download_hosts, do: ["atlassian.com", "atlassian.net", "atl-paas.net"]

  # Confluence hands out download links relative to the REST root
  # (`/rest/api/content/…/download`), and older exports use the web path
  # (`/download/attachments/…`). Each needs a different base.
  defp download_url(path) when is_binary(path) do
    if String.starts_with?(path, "/rest/api"),
      do: build_url(path, %{}),
      else: SafeURL.resolve(public_url(path), config()[:base_url])
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
      id: to_string(content["id"]),
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
  @spec json(:get | :post | :put | :delete, String.t(), Enumerable.t() | map() | nil) ::
          {:ok, term()} | {:error, term()}
  def json(method, path, payload \\ nil) do
    with {:ok, url} <- build_url(path, %{}) do
      json_request(method, url, payload)
    end
  end

  @doc """
  Uploads one attachment to a page.

  Used only by `mix confluence.seed`: the sync itself never writes.
  """
  @spec upload_attachment(integer(), String.t(), String.t(), binary()) ::
          {:ok, map()} | {:error, term()}
  def upload_attachment(page_id, filename, media_type, bytes) do
    boundary = "----mirror#{System.unique_integer([:positive])}"

    body = [
      "--#{boundary}\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"",
      filename,
      "\"\r\n",
      "Content-Type: ",
      media_type,
      "\r\n\r\n",
      bytes,
      "\r\n--#{boundary}--\r\n"
    ]

    with {:ok, url} <- build_url("/content/#{page_id}/child/attachment", %{}) do
      request_json(:post, url,
        headers: [
          # Confluence's XSRF check expects this header on uploads.
          {"x-atlassian-token", "no-check"},
          {"content-type", "multipart/form-data; boundary=#{boundary}"}
        ],
        body: IO.iodata_to_binary(body)
      )
    end
  end

  defp json_request(method, url, payload \\ nil) do
    options = if payload, do: [json: payload], else: []
    request_json(method, url, options)
  end

  defp request_json(method, url, options) do
    with {:ok, response} <- request(method, url, options) do
      cond do
        response.status in 200..299 and response.body in ["", nil] ->
          {:ok, %{}}

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
    # Confluence's own links (`_links.next`, attachment downloads) are relative to
    # the REST root and already carry `/rest/api`; the base below adds it.
    path = String.replace_prefix(path, "/rest/api", "")

    url =
      if String.starts_with?(path, ["http://", "https://"]) do
        path
      else
        api_base() <> path
      end

    url = if params == %{}, do: url, else: url <> "?" <> URI.encode_query(params)
    SafeURL.resolve(url, config()[:base_url])
  end

  # One attempt, one line in the sync log, one tick in `Traffic`. The line is
  # written when the answer is in, which is what gives it a status and a
  # latency; a call that will be retried says so and how long it will wait.
  defp request(method, url, options, attempt \\ 1) do
    {:ok, waited_ms} = RateLimiter.acquire()
    Traffic.throttled(waited_ms)

    {extra_headers, request_options} = Keyword.pop(options, :headers, [])

    defaults = [
      headers: auth_headers() ++ extra_headers,
      receive_timeout: config()[:request_timeout_ms] || 30_000,
      connect_options: [timeout: config()[:connect_timeout_ms] || 10_000],
      redirect: false,
      retry: false,
      decode_body: false
    ]

    # `:req_options` lets a deployment (or a test) supply transport options such
    # as a stubbed plug; anything set here wins over the defaults above.
    request =
      [method: method, url: url] ++ defaults ++ request_options ++ (config()[:req_options] || [])

    started = now_ms()

    case Req.request(request) do
      {:ok, %Req.Response{} = response} ->
        settle(response, method, url, options, attempt, now_ms() - started, waited_ms)

      {:error, reason} ->
        transport_failed(reason, method, url, options, attempt, waited_ms)
    end
  end

  defp settle(response, method, url, options, attempt, duration_ms, waited_ms) do
    facts = %{
      status: response.status,
      ms: duration_ms,
      bytes: body_size(response),
      attempt: attempt,
      waited: waited_ms
    }

    Traffic.request(response.status, duration_ms, facts.bytes)
    Traffic.slowest(call_label(method, url), duration_ms)

    if retryable?(response) and attempt < max_attempts() do
      retry(method, url, options, attempt, facts)
    else
      # A 404 is how the site says "no such page or group", and the sync handles
      # that as an answer, so it is not a failed call. Anything else that ends
      # the retry loop without content is.
      if response.status >= 400 and response.status != 404,
        do: Traffic.failed(response.status)

      store(response, method, url, facts)
    end
  end

  defp store(response, method, url, facts) do
    case check_size(response) do
      {:ok, %Req.Response{} = response} ->
        log_call(level_for(response.status), method, url, facts, nil)
        {:ok, response}

      {:error, {:body_too_large, size, limit} = reason} ->
        Traffic.failed(:body_too_large)

        log_call(
          :error,
          method,
          url,
          facts,
          "body of #{size} bytes is over the #{limit} byte cap"
        )

        {:error, reason}
    end
  end

  defp retry(method, url, options, attempt, facts) do
    Traffic.retry()
    wait_ms = retry_wait_ms(attempt)

    note = "retrying in #{wait_ms} ms (attempt #{attempt + 1} of #{max_attempts()})"
    log_call(:warn, method, url, facts, note)

    Process.sleep(wait_ms)
    request(method, url, options, attempt + 1)
  end

  defp transport_failed(reason, method, url, options, attempt, waited_ms) do
    facts = %{attempt: attempt, waited: waited_ms}

    if attempt < max_attempts() do
      Traffic.retry()
      wait_ms = retry_wait_ms(attempt)

      note =
        "transport error #{inspect(reason)}, retrying in #{wait_ms} ms " <>
          "(attempt #{attempt + 1} of #{max_attempts()})"

      log_call(:warn, method, url, facts, note)

      Process.sleep(wait_ms)
      request(method, url, options, attempt + 1)
    else
      Traffic.failed(:transport)
      log_call(:error, method, url, facts, "transport error #{inspect(reason)}")
      {:error, {:transport, reason}}
    end
  end

  # `GET /wiki/rest/api/content?limit=50&spaceKey=ENG&type=page 200 42 ms`
  defp log_call(level, method, url, facts, note) do
    line =
      [
        call_label(method, url),
        facts[:status],
        facts[:ms] && "#{facts[:ms]} ms",
        attempt_note(facts[:attempt]),
        note
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    # Only the facts the line cannot carry: the attempt a retried call is on, and
    # the wait the limiter imposed.
    details =
      %{
        kind: :http,
        method: method,
        url: path_of(url),
        status: facts[:status],
        ms: facts[:ms],
        bytes: facts[:bytes]
      }
      |> maybe_fact(:attempt, facts[:attempt] > 1 && facts[:attempt])
      |> maybe_fact(:waited, facts[:waited] > 0 && facts[:waited])

    Log.add(level, line, details)
  end

  defp maybe_fact(details, _key, false), do: details
  defp maybe_fact(details, _key, nil), do: details
  defp maybe_fact(details, key, value), do: Map.put(details, key, value)

  defp attempt_note(attempt) when attempt > 1, do: "(#{attempt}/#{max_attempts()})"
  defp attempt_note(_attempt), do: nil

  defp call_label(method, url), do: "#{method |> to_string() |> String.upcase()} #{path_of(url)}"

  defp path_of(url) do
    uri = URI.parse(url)

    # `expand` is the same column list on every call and says nothing about
    # which content was asked for, so it is left out of the line.
    query =
      if uri.query, do: uri.query |> URI.decode_query() |> Map.delete("expand"), else: %{}

    path = (uri.path || "/") <> if(query == %{}, do: "", else: "?" <> readable(query))

    # A download that leaves the site (the media API) means nothing without its
    # host, so the host is shown only when it is not the configured one.
    label = if uri.host == site_host(), do: path, else: "#{uri.host}#{path}"

    if String.length(label) > 160, do: String.slice(label, 0, 159) <> "…", else: label
  end

  # A CQL query is the one thing on the line an operator wants to read, so the
  # values are shown as written instead of percent-encoded.
  defp readable(query) do
    query
    |> Enum.sort()
    |> Enum.map_join("&", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp site_host do
    (config()[:base_url] || "") |> URI.parse() |> Map.get(:host)
  end

  defp body_size(%Req.Response{body: body}) when is_binary(body), do: byte_size(body)
  defp body_size(_response), do: 0

  defp now_ms, do: System.monotonic_time(:millisecond)

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

  defp level_for(status) when status in 200..399, do: :debug
  defp level_for(404), do: :debug
  defp level_for(401), do: :error
  defp level_for(403), do: :error
  defp level_for(status) when status >= 500, do: :error
  defp level_for(_status), do: :warn

  defp retry_wait_ms(attempt), do: retry_backoff_ms() * Integer.pow(2, attempt - 1)

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

  # Confluence's `_links.webui` are paths below the wiki root (`/spaces/ENG`),
  # while Cloud serves that wiki under `/wiki`. A path that already carries the
  # context path is left alone so it is never prefixed twice.
  defp public_url(path) when is_binary(path) do
    cond do
      String.starts_with?(path, ["http://", "https://"]) -> path
      origin() == "" -> path
      String.starts_with?(path, context_path()) -> origin() <> path
      true -> web_base() <> path
    end
  end

  defp web_base, do: origin() <> context_path()

  defp origin do
    config()[:base_url]
    |> to_string()
    |> String.trim_trailing("/")
    |> String.replace_suffix("/rest/api", "")
    |> String.replace_suffix("/wiki", "")
  end

  defp context_path do
    base =
      config()[:base_url]
      |> to_string()
      |> String.trim_trailing("/")
      |> String.replace_suffix("/rest/api", "")

    cond do
      String.ends_with?(base, "/wiki") -> "/wiki"
      String.contains?(base, ".atlassian.net") -> "/wiki"
      true -> ""
    end
  end

  defp format_cql_time(%DateTime{} = time) do
    time |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  defp config, do: Application.get_env(:confluence_phx_mirror, __MODULE__, [])
end
