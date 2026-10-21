defmodule ConfluencePhxMirror.Export.Zip do
  @moduledoc """
  Minimal streaming ZIP writer.

  Entries are **stored**, not deflated: markdown and already-compressed
  attachments gain nothing from a second pass, and streaming keeps memory flat
  for large spaces — one file is held at a time, never the archive.

  Sizes and CRCs are computed per entry before its local header is written, so
  no data descriptors (and no seekable output) are needed.
  """

  @local_header_signature 0x04034B50
  @central_signature 0x02014B50
  @eocd_signature 0x06054B50
  @utf8_flag 0x0800
  # 1980-01-01 00:00, the DOS epoch.
  @dos_date 0x0021
  @dos_time 0x0000

  @doc """
  Turns `{name, data}` pairs into a stream of chunks.

  `data` may be a binary, iodata or a zero-arity function; the function form
  keeps attachments lazy (read from the blob store while streaming).
  """
  @spec chunks(Enumerable.t()) :: Enumerable.t()
  def chunks(entries) do
    entries
    # The central directory can only be written once every offset is known, so
    # the stream gets one synthetic final element instead of relying on an
    # "after" callback that cannot emit.
    |> Stream.concat([:__end_of_archive__])
    |> Stream.transform({0, []}, &chunk/2)
  end

  defp chunk(:__end_of_archive__, {offset, central}) do
    {[central_directory(Enum.reverse(central), offset)], {offset, central}}
  end

  defp chunk({name, data}, {offset, central}) do
    data = if is_function(data, 0), do: data.(), else: data
    data = IO.iodata_to_binary(data)
    crc = :erlang.crc32(data)
    size = byte_size(data)
    header = local_header(name, crc, size)

    {[header, data], {offset + byte_size(header) + size, [{name, crc, size, offset} | central]}}
  end

  defp local_header(name, crc, size) do
    <<@local_header_signature::little-32, 20::little-16, @utf8_flag::little-16, 0::little-16,
      @dos_time::little-16, @dos_date::little-16, crc::little-32, size::little-32,
      size::little-32, byte_size(name)::little-16, 0::little-16, name::binary>>
  end

  defp central_record({name, crc, size, offset}) do
    <<@central_signature::little-32, 20::little-16, 20::little-16, @utf8_flag::little-16,
      0::little-16, @dos_time::little-16, @dos_date::little-16, crc::little-32, size::little-32,
      size::little-32, byte_size(name)::little-16, 0::little-16, 0::little-16, 0::little-16,
      0::little-16, 0::little-32, offset::little-32, name::binary>>
  end

  defp central_directory(records, offset) do
    body = records |> Enum.map_join(&central_record/1) |> IO.iodata_to_binary()
    count = length(records)

    eocd =
      <<@eocd_signature::little-32, 0::little-16, 0::little-16, count::little-16,
        count::little-16, byte_size(body)::little-32, offset::little-32, 0::little-16>>

    [body, eocd]
  end
end
