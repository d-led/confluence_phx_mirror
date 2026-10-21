defmodule ConfluencePhxMirror.Sync.PagePropertiesTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Sync.PageProperties

  test "reads the first table inside a pageproperties macro" do
    storage = """
    <p>Intro</p>
    <ac:structured-macro ac:name="pageproperties" ac:schema-version="1">
      <ac:rich-text-body>
        <table>
          <tbody>
            <tr><th>Owner</th><td>Platform</td></tr>
            <tr><th>Status</th><td>Active</td></tr>
          </tbody>
        </table>
      </ac:rich-text-body>
    </ac:structured-macro>
    """

    assert PageProperties.parse(storage) == [
             %{key: "Owner", value: "Platform"},
             %{key: "Status", value: "Active"}
           ]
  end

  test "ignores rows without a key and keeps the first value of a key" do
    storage = """
    <ac:structured-macro ac:name="pageproperties">
      <ac:rich-text-body>
        <table><tbody>
          <tr><td>Owner</td><td>Platform</td></tr>
          <tr><td></td><td>orphan</td></tr>
          <tr><td>Owner</td><td>Docs</td></tr>
        </tbody></table>
      </ac:rich-text-body>
    </ac:structured-macro>
    """

    assert PageProperties.parse(storage) == [%{key: "Owner", value: "Platform"}]
  end

  test "returns nothing when the macro is absent" do
    assert PageProperties.parse("<p>No macros here.</p>") == []
    assert PageProperties.parse(nil) == []
  end
end
