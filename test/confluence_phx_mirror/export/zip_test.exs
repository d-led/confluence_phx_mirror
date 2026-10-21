defmodule ConfluencePhxMirror.Export.ZipTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Export.Zip

  test "produces an archive that a ZIP reader accepts" do
    files =
      [{"a.md", "hi"}, {"b/c.md", fn -> "there" end}]
      |> Zip.chunks()
      |> archive_contents()

    assert files == %{"a.md" => "hi", "b/c.md" => "there"}
  end

  test "an empty entry list is still a valid archive" do
    assert Zip.chunks([]) |> archive_contents() == %{}
  end

  defp archive_contents(chunks) do
    path =
      Path.join(System.tmp_dir!(), "mirror-zip-#{System.unique_integer([:positive])}.zip")

    File.write!(path, chunks |> Enum.to_list() |> IO.iodata_to_binary())

    try do
      {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])
      Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
    after
      File.rm(path)
    end
  end
end
