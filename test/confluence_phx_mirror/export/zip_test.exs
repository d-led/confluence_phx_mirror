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

  # A reader looks at the dates in their file manager: an archive of today's
  # pages that says 1980 is a lie, and one that says 2030 is another.
  describe "the moment each entry says" do
    test "is the archive's own, one for every entry" do
      entries = [{"a.md", "hi"}, {"b.md", fn -> "there" end}]
      at = ~U[2026-10-30 12:34:56Z]

      stamps =
        entries
        |> Zip.chunks(at: at)
        |> Enum.to_list()
        |> IO.iodata_to_binary()
        |> stamps()

      assert stamps == [at, at]
    end

    test "is the file's own where the archive is told one" do
      # An even second, because that is all a ZIP can hold — the case below is
      # about the odd one.
      changed = ~U[2021-03-04 05:06:08Z]
      at = ~U[2026-10-30 12:34:56Z]

      [page, attachment] =
        [{"page.html", "hi"}, {"files/plan.png", "bytes", changed}]
        |> Zip.chunks(at: at)
        |> Enum.to_list()
        |> IO.iodata_to_binary()
        |> stamps()

      assert page == at
      assert attachment == changed
    end

    test "rounds to the two seconds a ZIP can hold" do
      odd = ~U[2026-10-30 12:34:57Z]

      [stamp] =
        [{"a.md", "hi", odd}]
        |> Zip.chunks()
        |> Enum.to_list()
        |> IO.iodata_to_binary()
        |> stamps()

      assert stamp == %{odd | second: 56}
    end
  end

  defp archive_contents(entries), do: entries |> archive_bytes() |> unzip()

  defp archive_bytes(entries) do
    entries
    |> Zip.chunks()
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  # Every local header in the archive, read back as the moment it names — a
  # decoder of its own, so the writer is checked rather than restated.
  defp stamps(archive), do: read_stamps(archive, [])

  defp read_stamps(archive, acc) do
    case :binary.match(archive, <<0x50, 0x4B, 3, 4>>) do
      :nomatch ->
        Enum.reverse(acc)

      {at, _length} ->
        <<_signature::binary-size(4), _rest::binary-size(6), time::little-16, date::little-16,
          tail::binary>> = binary_part(archive, at, byte_size(archive) - at)

        read_stamps(tail, [decode(time, date) | acc])
    end
  end

  # A DOS date back to the instant it names: the year is counted from 1980, the
  # seconds are stored halved, and the moment is UTC.
  defp decode(time, date) do
    second = Bitwise.band(time, 0x1F) * 2
    minute = Bitwise.band(Bitwise.bsr(time, 5), 0x3F)
    hour = Bitwise.bsr(time, 11)
    day = Bitwise.band(date, 0x1F)
    month = Bitwise.band(Bitwise.bsr(date, 5), 0x0F)
    year = Bitwise.bsr(date, 9) + 1980

    {:ok, at} =
      DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second), "Etc/UTC")

    at
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
