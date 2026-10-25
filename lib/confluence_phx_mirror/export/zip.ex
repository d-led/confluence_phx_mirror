defmodule ConfluencePhxMirror.Export.Zip do
  @moduledoc """
  Minimal streaming ZIP writer.

  Entries are deflated when that makes them smaller and stored when it does not:
  HTML, Markdown and JSON shrink several times over, while attachments are
  usually already compressed and gain nothing from a second pass. Sizes and
  CRCs are computed per entry before its header is written, so no data
  descriptors — and no seekable output — are needed: the archive is written to
  a socket as it is built, one entry at a time.

  A whole wiki passes the classic format's limits, so ZIP64 is used where it is
  required: an end-of-central-directory ZIP64 record when the entry count or the
  directory size does not fit, and a per-entry extra field when one entry, or
  its offset, is larger than 4 GiB. Without that, a site of more than 65,535
  files (a page is two: its HTML and its Markdown) produces an archive a reader
  cannot open.
  """

  @local_header_signature 0x04034B50
  @central_signature 0x02014B50
  @eocd_signature 0x06054B50
  @zip64_eocd_signature 0x06064B50
  @zip64_locator_signature 0x07064B50
  @zip64_extra_id 0x0001
  @zip64_version 45
  @classic_version 20
  @utf8_flag 0x0800
  @store 0
  @deflate 8
  # The largest value a classic 32-bit field can hold; it doubles as the
  # "look in the extra field" marker.
  @limit 0xFFFFFFFF
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
    records = Enum.reverse(central)
    directory = records |> Enum.map_join(&central_record/1) |> IO.iodata_to_binary()

    {[directory | end_records(length(records), byte_size(directory), offset)], {offset, central}}
  end

  defp chunk({name, data}, {offset, central}) do
    data = if is_function(data, 0), do: data.(), else: data
    data = IO.iodata_to_binary(data)
    crc = :erlang.crc32(data)
    {method, payload} = deflate(data)

    record = {name, crc, byte_size(data), byte_size(payload), method, offset}
    header = local_header(record)
    {[header, payload], {offset + byte_size(header) + byte_size(payload), [record | central]}}
  end

  # ---------------------------------------------------------------------------
  # Headers
  # ---------------------------------------------------------------------------

  defp local_header({name, crc, size, compressed, method, offset}) do
    zip64? = zip64?(size, compressed, offset)
    extra = extra(size, compressed, nil, zip64?)

    <<@local_header_signature::little-32, version(zip64?)::little-16, @utf8_flag::little-16,
      method::little-16, @dos_time::little-16, @dos_date::little-16, crc::little-32,
      field(compressed, zip64?)::little-32, field(size, zip64?)::little-32,
      byte_size(name)::little-16, byte_size(extra)::little-16, name::binary, extra::binary>>
  end

  defp central_record({name, crc, size, compressed, method, offset}) do
    zip64? = zip64?(size, compressed, offset)
    extra = extra(size, compressed, offset, zip64?)

    <<@central_signature::little-32, version(zip64?)::little-16, version(zip64?)::little-16,
      @utf8_flag::little-16, method::little-16, @dos_time::little-16, @dos_date::little-16,
      crc::little-32, field(compressed, zip64?)::little-32, field(size, zip64?)::little-32,
      byte_size(name)::little-16, byte_size(extra)::little-16, 0::little-16, 0::little-16,
      0::little-16, 0::little-32, field(offset, zip64?)::little-32, name::binary, extra::binary>>
  end

  # A reader fills in whichever 32-bit fields read `0xFFFFFFFF` from the extra
  # field, in this order: uncompressed size, compressed size, then the local
  # header's offset (central directory only). All three are written whenever one
  # of them is needed, so the fixed fields and the extra always agree.
  defp extra(_size, _compressed, _offset, false), do: <<>>

  defp extra(size, compressed, offset, true) do
    values = [size, compressed] ++ if(offset, do: [offset], else: [])

    <<@zip64_extra_id::little-16, length(values) * 8::little-16,
      Enum.map_join(values, &<<&1::little-64>>)::binary>>
  end

  defp zip64?(size, compressed, offset) do
    size >= @limit or compressed >= @limit or (offset != nil and offset >= @limit)
  end

  defp field(_value, true), do: @limit
  defp field(value, false), do: value

  defp version(true), do: @zip64_version
  defp version(false), do: @classic_version

  # ---------------------------------------------------------------------------
  # End of central directory
  # ---------------------------------------------------------------------------

  defp end_records(count, directory_size, directory_offset) do
    if count > 0xFFFF or directory_size >= @limit or directory_offset >= @limit do
      zip64_offset = directory_offset + directory_size

      [
        <<@zip64_eocd_signature::little-32, 44::little-64, @zip64_version::little-16,
          @zip64_version::little-16, 0::little-32, 0::little-32, count::little-64,
          count::little-64, directory_size::little-64, directory_offset::little-64>>,
        <<@zip64_locator_signature::little-32, 0::little-32, zip64_offset::little-64,
          1::little-32>>,
        eocd(0xFFFF, @limit, @limit)
      ]
    else
      [eocd(count, directory_size, directory_offset)]
    end
  end

  defp eocd(count, size, offset) do
    <<@eocd_signature::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
      size::little-32, offset::little-32, 0::little-16>>
  end

  # ---------------------------------------------------------------------------
  # Compression
  # ---------------------------------------------------------------------------

  # Raw deflate (window bits -15), which is what a ZIP entry holds. A payload
  # that does not shrink is stored instead: deflating an already compressed
  # attachment only costs time and bytes.
  defp deflate(""), do: {@store, ""}

  defp deflate(data) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    compressed = IO.iodata_to_binary(:zlib.deflate(z, data, :finish))
    :ok = :zlib.deflateEnd(z)
    :ok = :zlib.close(z)

    if byte_size(compressed) < byte_size(data) do
      {@deflate, compressed}
    else
      {@store, data}
    end
  end
end
