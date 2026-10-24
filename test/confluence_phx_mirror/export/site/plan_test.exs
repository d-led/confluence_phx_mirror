defmodule ConfluencePhxMirror.Export.Site.PlanTest do
  @moduledoc """
  The parts of an archive's plan that are decided without a database: how the
  page tree nests and how far a file is from the archive root.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Export.Site

  describe "tree/1" do
    test "nests a page under its parent, siblings in the order the rows came" do
      tree =
        Site.tree([
          row(1, nil, "Handbook"),
          row(2, 1, "Getting Started"),
          row(3, 2, "Architecture")
        ])

      assert [
               %{
                 title: "Handbook",
                 children: [
                   %{title: "Getting Started", children: [%{title: "Architecture", children: []}]}
                 ]
               }
             ] = tree
    end

    test "a page whose parent the archive does not carry becomes a root" do
      tree = Site.tree([row(1, nil, "Handbook"), row(2, 99, "Restricted parent")])

      assert Enum.map(tree, & &1.title) == ["Handbook", "Restricted parent"]
    end
  end

  describe "prefix/1" do
    test "counts the folders between a file and the archive root" do
      assert Site.prefix("index.html") == ""
      assert Site.prefix("search.html") == ""
      assert Site.prefix("spaces/ENG/index.html") == "../../"
      assert Site.prefix("spaces/ENG/pages/1002.html") == "../../../"
    end
  end

  defp row(id, parent_id, title) do
    %{id: id, confluence_id: id, parent_id: parent_id, title: title}
  end
end
