defmodule ConfluencePhxMirror.Mcp.Tools.ConfigurationTest do
  @moduledoc """
  What the mirror says about itself, and what it refuses to say.

  Two things are being specified here. The first is the shape of the answer: the
  site it mirrors, how often it syncs, what it holds — and, when the desktop tool
  contributes it, the folder a person can open and the address an assistant is
  pointed at. The second is the boundary: a reader who is not an administrator
  gets nothing, and no answer ever contains a credential.
  """

  use ConfluencePhxMirror.DataCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts.Scope
  alias ConfluencePhxMirror.Mcp.Tools
  alias ConfluencePhxMirror.TestConfig

  describe "confluence_mirror_configuration" do
    test "an administrator is told how this installation is set up" do
      scope = admin_scope("config-admin@example.com")

      assert {:ok, %{text: text, structured: configuration}} =
               Tools.call("confluence_mirror_configuration", %{}, scope)

      assert configuration["site"]["name"] =~ "Confluence"
      assert is_integer(configuration["sync"]["interval_seconds"])
      assert is_integer(configuration["sync"]["reconcile_interval_seconds"])
      assert is_integer(configuration["content"]["spaces"])
      assert is_integer(configuration["content"]["absent_pages"])

      assert text =~ "spaces mirrored"
      assert text =~ "sync every"
    end

    test "a reader who is not an administrator is told nothing" do
      scope = Scope.for_user(user_fixture(%{email: "config-reader@example.com"}))

      assert Tools.call("confluence_mirror_configuration", %{}, scope) ==
               {:error, "Only mirror administrators can read the configuration."}
    end

    test "the desktop workspace, when there is one, says where the data lives" do
      in_workspace(%{
        root: "/tmp/confluence-export",
        site: "https://example.atlassian.net",
        mcp_url: "http://127.0.0.1:43100/api/mcp"
      })

      assert {:ok, %{structured: configuration}} =
               Tools.call(
                 "confluence_mirror_configuration",
                 %{},
                 admin_scope("config-desktop@example.com")
               )

      assert configuration["workspace"]["mcp_url"] == "http://127.0.0.1:43100/api/mcp"
      assert configuration["workspace"]["root"] == "/tmp/confluence-export"
    end

    test "a deployment has no workspace, and says so by leaving it out" do
      assert {:ok, %{structured: configuration}} =
               Tools.call(
                 "confluence_mirror_configuration",
                 %{},
                 admin_scope("config-server@example.com")
               )

      refute Map.has_key?(configuration, "workspace")
    end

    test "no credential is ever part of the answer" do
      in_workspace(%{
        root: "/tmp/workspace",
        account: "someone@example.com",
        mcp_url: "http://127.0.0.1:43100/api/mcp"
      })

      assert {:ok, %{structured: configuration}} =
               Tools.call(
                 "confluence_mirror_configuration",
                 %{},
                 admin_scope("config-secret@example.com")
               )

      assert configuration |> keys() |> Enum.any?(&(&1 =~ ~r/token|secret|password|credential/i)) ==
               false
    end
  end

  defp admin_scope(email) do
    Scope.for_user(user_fixture(%{email: email, role: "admin"}))
  end

  # The desktop tool puts this in the application environment; a deployment never
  # does. `TestConfig` puts the deployment back when the test ends — the
  # environment outlives the test.
  defp in_workspace(info), do: TestConfig.put(:workspace_info, fn -> info end)

  defp keys(value) when is_map(value), do: Enum.flat_map(value, fn {k, v} -> [k | keys(v)] end)
  defp keys(value) when is_list(value), do: Enum.flat_map(value, &keys/1)
  defp keys(_value), do: []
end
