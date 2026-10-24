defmodule ConfluencePhxMirrorWeb.Mcp.Protocol do
  @moduledoc """
  The MCP JSON-RPC surface: `initialize`, `ping`, `tools/list` and `tools/call`.

  Deliberately stateless. The Streamable HTTP transport lets a server hand out
  an `Mcp-Session-Id` and keep state per session; this one does not, so a
  request may land on any replica and no client has to send a header back. What
  a session would hold — which tools exist, whether the client finished
  initializing — cannot differ between requests here, because the tool list is
  compiled and every call authenticates itself.

  The HTTP details (status codes, the `Mcp-Session-Id`-less contract, methods
  that are not POST) belong to `ConfluencePhxMirrorWeb.McpController`; this
  module decides what a well-formed message means.
  """

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Mcp
  alias ConfluencePhxMirror.Mcp.Tools

  @type outcome :: {:reply, map()} | :accepted | {:invalid_request, map()}

  @doc """
  Answers one JSON-RPC message.

  A notification (no `id`) is accepted and answered with nothing: MCP's only
  client notification after initialization is `notifications/initialized`, and
  a server must not answer it.
  """
  @spec handle(term(), Scope.t()) :: outcome()
  def handle(%{"jsonrpc" => "2.0", "method" => "notifications/" <> _method}, _scope) do
    :accepted
  end

  def handle(%{"jsonrpc" => "2.0", "method" => method} = message, scope)
      when is_binary(method) do
    case Map.get(message, "id") do
      nil -> :accepted
      id -> dispatch(method, Map.get(message, "params") || %{}, id, scope)
    end
  end

  def handle(%{"jsonrpc" => _other}, _scope) do
    {:invalid_request, error(nil, -32_600, "Only JSON-RPC 2.0 messages are supported.")}
  end

  def handle(message, _scope) when is_map(message) do
    {:invalid_request, error(nil, -32_600, "A JSON-RPC message needs a `method`.")}
  end

  def handle(_message, _scope) do
    {:invalid_request, error(nil, -32_600, "Batches are not supported; send one message.")}
  end

  defp dispatch("initialize", params, id, _scope) do
    {:reply,
     result(id, %{
       "protocolVersion" => Mcp.negotiate(version(params)),
       "capabilities" => %{"tools" => %{"listChanged" => false}},
       "serverInfo" => Mcp.server_info(),
       "instructions" => Mcp.instructions()
     })}
  end

  defp dispatch("ping", _params, id, _scope), do: {:reply, result(id, %{})}

  defp dispatch("tools/list", _params, id, _scope) do
    {:reply, result(id, %{"tools" => Tools.definitions()})}
  end

  defp dispatch("tools/call", params, id, scope) do
    with {:ok, name} <- tool_name(params),
         {:ok, arguments} <- tool_arguments(params) do
      case Tools.call(name, arguments, scope) do
        {:ok, %{text: text} = ok} ->
          {:reply, result(id, tool_result(text, Map.get(ok, :structured)))}

        {:error, message} ->
          {:reply, result(id, tool_error(message))}

        :unknown_tool ->
          {:reply, error(id, -32_602, "Unknown tool: #{name}")}
      end
    else
      {:error, message} -> {:reply, error(id, -32_602, message)}
    end
  end

  defp dispatch(method, _params, id, _scope) do
    {:reply, error(id, -32_601, "Method not found: #{method}")}
  end

  defp version(%{"protocolVersion" => version}), do: version
  defp version(_params), do: nil

  defp tool_name(%{"name" => name}) when is_binary(name) and name != "", do: {:ok, name}
  defp tool_name(_params), do: {:error, "`name` is required."}

  defp tool_arguments(%{"arguments" => nil}), do: {:ok, %{}}
  defp tool_arguments(%{"arguments" => arguments}) when is_map(arguments), do: {:ok, arguments}
  defp tool_arguments(%{} = params) when not is_map_key(params, "arguments"), do: {:ok, %{}}
  defp tool_arguments(_params), do: {:error, "`arguments` must be a JSON object."}

  defp tool_result(text, structured) do
    base = %{"content" => [%{"type" => "text", "text" => text}], "isError" => false}
    if is_map(structured), do: Map.put(base, "structuredContent", structured), else: base
  end

  defp tool_error(message) do
    %{"content" => [%{"type" => "text", "text" => message}], "isError" => true}
  end

  defp result(id, payload), do: %{"jsonrpc" => "2.0", "id" => id, "result" => payload}

  defp error(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end
end
