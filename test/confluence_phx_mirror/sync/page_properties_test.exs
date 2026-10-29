defmodule ConfluencePhxMirror.Sync.PagePropertiesTest do
  @moduledoc """
  The two shapes below are what Confluence Cloud stores for the two layouts — a
  page saved with each and read back through `body.storage` — not an
  idealisation of them. The macro itself says nothing about which one it is; the
  heading does.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.PageProperties

  describe "a property table whose heading is a column" do
    test "each row is one property" do
      storage =
        macro("""
        <table><tbody>
          <tr><th>Owner</th><td>Platform</td></tr>
          <tr><th>Status</th><td>Active</td></tr>
        </tbody></table>
        """)

      assert PageProperties.parse(storage) == [
               %{key: "Owner", value: "Platform"},
               %{key: "Status", value: "Active"}
             ]
    end

    test "a row with no key is not a property" do
      storage =
        macro("""
        <table><tbody>
          <tr><td></td><td>orphan</td></tr>
          <tr><td>Owner</td><td>Platform</td></tr>
        </tbody></table>
        """)

      assert PageProperties.parse(storage) == [%{key: "Owner", value: "Platform"}]
    end

    test "a key declared twice keeps the value a reader sees first" do
      storage =
        macro("""
        <table><tbody>
          <tr><th>Owner</th><td>Platform</td></tr>
          <tr><th>Owner</th><td>Docs</td></tr>
        </tbody></table>
        """)

      assert PageProperties.parse(storage) == [%{key: "Owner", value: "Platform"}]
    end
  end

  describe "a property table whose heading is a row" do
    test "the keys run across the top and the values beneath them" do
      storage =
        macro("""
        <table><tbody>
          <tr><th>Owner</th><th>Status</th></tr>
          <tr><td>Platform</td><td>Active</td></tr>
        </tbody></table>
        """)

      assert PageProperties.parse(storage) == [
               %{key: "Owner", value: "Platform"},
               %{key: "Status", value: "Active"}
             ]
    end

    test "a heading row is never read as key/value pairs" do
      # What the parser did before it knew the layout: this table's keys became
      # `Owner -> Status` and `Platform -> Active`, so a report published two
      # invented columns and lost both values.
      storage =
        macro("""
        <table><tbody>
          <tr><th>Owner</th><th>Status</th></tr>
          <tr><td>Platform</td><td>Active</td></tr>
        </tbody></table>
        """)

      keys = storage |> PageProperties.parse() |> Enum.map(& &1.key)

      assert keys == ["Owner", "Status"]
    end

    test "a key whose value cell is missing still becomes a column" do
      storage =
        macro("""
        <table><tbody>
          <tr><th>Owner</th><th>Status</th><th>Team</th></tr>
          <tr><td>Platform</td><td>Active</td></tr>
        </tbody></table>
        """)

      assert PageProperties.parse(storage) == [
               %{key: "Owner", value: "Platform"},
               %{key: "Status", value: "Active"},
               %{key: "Team", value: ""}
             ]
    end
  end

  test "a cell's markup reads as its words, not run together" do
    storage =
      macro("""
      <table><tbody>
        <tr><th>Owner</th><td><p>Platform</p><p>and Docs</p></td></tr>
      </tbody></table>
      """)

    assert PageProperties.parse(storage) == [%{key: "Owner", value: "Platform and Docs"}]
  end

  test "the first table of the macro is the one that counts" do
    storage =
      macro("""
      <table><tbody><tr><th>Owner</th><td>Platform</td></tr></tbody></table>
      <table><tbody><tr><th>Ignored</th><td>yes</td></tr></tbody></table>
      """)

    assert PageProperties.parse(storage) == [%{key: "Owner", value: "Platform"}]
  end

  test "the report macro is not a properties table" do
    report = """
    <ac:structured-macro ac:name="pageproperties-report">
      <ac:parameter ac:name="cql">label = "decision"</ac:parameter>
    </ac:structured-macro>
    """

    assert PageProperties.parse(report) == []
  end

  test "returns nothing when the macro is absent" do
    assert PageProperties.parse("<p>No macros here.</p>") == []
    assert PageProperties.parse(nil) == []
  end

  defp macro(table) do
    """
    <p>Intro</p>
    <ac:structured-macro ac:name="pageproperties" ac:schema-version="1">
      <ac:rich-text-body>#{table}</ac:rich-text-body>
    </ac:structured-macro>
    """
  end
end
