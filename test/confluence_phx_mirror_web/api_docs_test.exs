defmodule ConfluencePhxMirrorWeb.ApiDocsTest do
  @moduledoc """
  The API description is generated from the router and described by hand. These
  tests keep the two in step: a route without a description fails, and the
  document and the page cannot drift apart because one renders the other.
  """
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirrorWeb.Api.OpenApi

  test "every API route the router serves is described" do
    assert OpenApi.undocumented() == []
  end

  test "the document is OpenAPI 3.1 and lists every route the router serves", %{conn: conn} do
    document = conn |> get("/api/openapi.json") |> json_response(200)

    assert document["openapi"] == "3.1.0"

    assert document["paths"] |> Map.keys() |> Enum.sort() ==
             OpenApi.routes() |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()
  end

  test "every operation answers with at least one described response", %{conn: conn} do
    document = conn |> get("/api/openapi.json") |> json_response(200)

    for {path, operations} <- document["paths"],
        {_verb, operation} <- operations do
      assert operation["responses"] != %{}, "#{path} describes no response"
    end
  end

  test "a described operation carries its summary, parameters and security", %{conn: conn} do
    document = conn |> get("/api/openapi.json") |> json_response(200)

    show = document["paths"]["/api/v1/pages/{id}"]["get"]

    assert show["summary"] == "One page, with both bodies"
    assert [%{"name" => "id", "in" => "path", "required" => true}] = show["parameters"]
    assert show["security"] == [%{"bearer" => []}, %{"basic" => []}]

    assert document["paths"]["/health"]["get"]["security"] == nil
  end

  test "every schema reference points at a schema that exists" do
    document = OpenApi.document()

    references =
      document
      |> collect_refs()
      |> Enum.uniq()

    for "#/components/schemas/" <> schema <- references do
      assert document["components"]["schemas"][schema],
             "the document refers to #{schema}, which it does not define"
    end
  end

  test "the page renders the same document", %{conn: conn} do
    html = conn |> get("/api/docs") |> html_response(200)

    assert html =~ "The mirror API"
    assert html =~ "/api/v1/spaces"
    assert html =~ "Confluence-compatible"
    assert html =~ "Authorization: Bearer"
  end

  test "a deployment can switch the surface off", %{conn: conn} do
    ConfluencePhxMirror.TestConfig.put(:api_docs, false)

    assert %{status: 404} = get(conn, "/api/openapi.json")
    assert %{status: 404} = get(conn, "/api/docs")
  end

  # Walks the document for `$ref` strings, whatever the nesting.
  defp collect_refs(%{"$ref" => ref}), do: [ref]
  defp collect_refs(map) when is_map(map), do: Enum.flat_map(Map.values(map), &collect_refs/1)
  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_scalar), do: []
end
