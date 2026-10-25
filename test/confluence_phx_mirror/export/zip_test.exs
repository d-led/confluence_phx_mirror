defmodule ConfluencePhxMirror.Export.ZipTest do
  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Export.Zip

  test "produces an archive that a ZIP reader accepts" do
    files =
      [{"a.md", "hi"}, {"b/c.md", fn -> "there" end}]
      |> archive_contents()

    assert files == %{"a.md" => "hi", "b/c.md" => "there"}
  end

  test "an empty entry list is still a valid archive" do
    assert archive_contents([]) == %{}
  end

  test "an entry that compresses is deflated, not stored" do
    text = String.duplicate("a page of prose, again and again. ", 1_000)

    archive = archive_bytes([{"page.html", text}])

    assert byte_size(archive) < div(byte_size(text), 4)
    assert unzip(archive) == %{"page.html" => text}
  end

  test "an entry that cannot be compressed is stored" do
    # Attachments are usually already compressed; deflating them again would
    # make the archive bigger, not smaller.
    random = :crypto.strong_rand_bytes(4_096)

    archive = archive_bytes([{"plan.png", random}])

    assert byte_size(archive) < byte_size(random) + 200
    assert unzip(archive) == %{"plan.png" => random}
  end

  test "more entries than the classic format counts stay readable" do
    entries = for i <- 1..65_536, do: {"pages/#{i}.html", "page #{i}"}

    files = archive_contents(entries)

    assert map_size(files) == 65_536
    assert files["pages/65536.html"] == "page 65536"
  end

  defp archive_contents(entries), do: entries |> archive_bytes() |> unzip()

  defp archive_bytes(entries) do
    entries
    |> Zip.chunks()
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  defp unzip(archive) do
    path =
      Path.join(System.tmp_dir!(), "mirror-zip-#{System.unique_integer([:positive])}.zip")

    File.write!(path, archive)

    try do
      {:ok, files} = :zip.extract(String.to_charlist(path), [:memory])
      Map.new(files, fn {name, data} -> {List.to_string(name), data} end)
    after
      File.rm(path)
    end
  end
end
