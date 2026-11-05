defmodule AshBulkDurable.Sheet.BoundedZip do
  @moduledoc """
  Reads entries out of a companion ZIP under a hard output budget, so a
  user-supplied archive can't exhaust the node's memory.

  `:zip.zip_get/2` cannot be used for untrusted input. It inflates an entry
  fully into a binary before returning, and it does not trust — or stop at —
  the size the archive declares: an archive whose central directory claims 100
  bytes still yields the whole stream. Neither does the declared size help as a
  pre-check on its own, since it is attacker-controlled. And `max_heap_size` on
  the extracting process does not bound it either, because binaries above 64
  bytes live off-heap and never count against the process heap.

  So the budget has to be enforced *during* inflation. Deflate's maximum
  expansion is ~1032:1, so feeding the compressed stream in small chunks caps
  what a single `:zlib.inflate/2` call can return: at `@inflate_chunk_bytes` in,
  at most ~4 MB comes out, and the running total is checked between calls. Peak
  memory is therefore the budget plus one chunk's worth of expansion, whatever
  the archive claims about itself.

  The bound is on how much input reaches one `:zlib.inflate/2` call, not on how
  much comes off disk, so reads are `@read_block_bytes` and each block is handed
  to zlib a chunk at a time. The descriptor is shared by the concurrent per-row
  tasks and every read is a message round-trip to its file process, so reading
  in inflate-sized pieces would cost thousands of them per entry.

  What inflates cleanly is still not necessarily what the archive shipped, so
  the output is checked against the entry's CRC — a truncated stream included,
  since it ends without complaint and yields a short body. Without that check a
  corrupt archive lands corrupt bytes at S3 with nothing reported.

  `open/1` reads the central directory only — nothing is inflated until
  `extract/3`, which is the only function that produces bytes.
  """

  require Record

  Record.defrecordp(:zip_file, Record.extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  # 4 KB in bounds a single inflate call to ~4 MB out at deflate's maximum
  # expansion ratio. Larger chunks void the bound: at 64 KB a 50 MB entry
  # arrives in one call.
  @inflate_chunk_bytes 4096

  # Disk reads are independent of the inflate bound — see the moduledoc.
  @read_block_bytes 256 * 1024

  @local_header_bytes 30
  @data_descriptor_bytes 8
  @data_descriptor_signature 0x08074B50
  # Sizes and CRC sit in a trailing data descriptor rather than the local
  # header when this flag is set, which is how a streaming writer emits an
  # entry it hasn't finished reading yet.
  @streamed_flag 0x08
  @deflated 8
  @stored 0

  @doc """
  Index the archive by entry basename. Reads the central directory only.

  Returns `{:ok, %{fd: fd, index: index}}`. The caller must `close/1`. Two
  entries sharing a basename are rejected here, before any row runs, so the
  ambiguity can't silently land the wrong bytes at S3.
  """
  def open(path) do
    # The descriptor is taken first so an unreadable path reports as an open
    # failure rather than surfacing as a malformed archive.
    with {:ok, fd} <- open_read(path) do
      case index(path) do
        {:ok, index} ->
          {:ok, %{fd: fd, index: index}}

        {:error, _reason} = error ->
          :file.close(fd)
          error
      end
    end
  end

  defp index(path) do
    with {:ok, entries} <- list_dir(path) do
      index_by_basename(entries)
    end
  end

  @doc "Release the archive's file descriptor."
  def close(%{fd: fd}), do: :file.close(fd)
  def close(_state), do: :ok

  @doc """
  Inflate one indexed entry, refusing to produce more than `max_bytes`.

  `{:error, {:too_large, declared}}` when the archive itself declares more than
  the budget — a cheap reject that inflates nothing. `{:error, :too_large}` when
  the stream exceeds the budget regardless of what was declared, which is the
  case the declared size cannot be trusted to catch. `{:error, :bad_crc}` when
  the bytes produced are not the bytes the archive recorded.
  """
  def extract(%{fd: fd}, entry, max_bytes) do
    %{offset: offset, comp_size: comp_size, declared_size: declared_size} = entry

    if declared_size > max_bytes do
      {:error, {:too_large, declared_size}}
    else
      with {:ok, header} <- read_local_header(fd, offset),
           {:ok, body} <- read_entry(fd, header, comp_size, max_bytes),
           :ok <- verify_crc(fd, header, comp_size, body) do
        {:ok, body}
      end
    end
  end

  @doc "Declared uncompressed size of an indexed entry, per the archive."
  def declared_size(%{declared_size: size}), do: size

  # ---- Index ---------------------------------------------------------------

  defp list_dir(path) do
    case :zip.list_dir(String.to_charlist(path)) do
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:zip_list_failed, reason}}
    end
  end

  defp open_read(path) do
    # Deliberately not `:raw`: raw descriptors are usable only by the process
    # that opened them, and extraction bulk actions in per-row tasks.
    case :file.open(String.to_charlist(path), [:read, :binary]) do
      {:ok, fd} -> {:ok, fd}
      {:error, reason} -> {:error, {:zip_open_failed, reason}}
    end
  end

  defp index_by_basename(entries) do
    entries
    |> Enum.flat_map(&entry_fields/1)
    |> Enum.reduce_while({:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      basename = Path.basename(name)

      cond do
        basename == "" or String.ends_with?(name, "/") ->
          {:cont, {:ok, acc}}

        Map.has_key?(acc, basename) ->
          {:halt, {:error, {:duplicate_basename, basename}}}

        true ->
          {:cont, {:ok, Map.put(acc, basename, entry)}}
      end
    end)
  end

  defp entry_fields(zip_file(name: name, info: info, offset: offset, comp_size: comp_size)) do
    file_info(size: declared_size) = info

    [
      {to_string(name),
       %{
         name: to_string(name),
         offset: offset,
         comp_size: comp_size,
         declared_size: declared_size
       }}
    ]
  end

  defp entry_fields(_other), do: []

  # ---- Reading -------------------------------------------------------------

  # The compressed data starts after the local header, whose name and extra
  # fields are variable length — and whose lengths can differ from the central
  # directory's copy, so they are read from the local header itself.
  defp read_local_header(fd, offset) do
    case :file.pread(fd, offset, @local_header_bytes) do
      {:ok,
       <<0x04034B50::little-32, _version::little-16, flags::little-16, method::little-16,
         _time::little-16, _date::little-16, crc::little-32, _csize::little-32, _usize::little-32,
         name_len::little-16, extra_len::little-16>>} ->
        {:ok,
         %{
           method: method,
           crc: crc,
           streamed?: Bitwise.band(flags, @streamed_flag) != 0,
           data_offset: offset + @local_header_bytes + name_len + extra_len
         }}

      {:ok, _not_a_local_header} ->
        {:error, :bad_local_header}

      :eof ->
        {:error, :bad_local_header}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp read_entry(fd, %{method: @stored, data_offset: data_offset}, comp_size, max_bytes) do
    # Stored entries expand 1:1, so one bounded read settles it.
    case :file.pread(fd, data_offset, min(comp_size, max_bytes + 1)) do
      {:ok, body} when byte_size(body) > max_bytes -> {:error, :too_large}
      {:ok, body} -> {:ok, body}
      :eof -> {:ok, <<>>}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end

  defp read_entry(fd, %{method: @deflated, data_offset: data_offset}, comp_size, max_bytes) do
    z = :zlib.open()
    :zlib.inflateInit(z, -15)

    try do
      read_blocks(fd, data_offset, comp_size, max_bytes, z, [], 0)
    catch
      :error, _reason -> {:error, :corrupt_entry}
    after
      :zlib.close(z)
    end
  end

  defp read_entry(_fd, %{method: method}, _comp_size, _max_bytes) do
    {:error, {:unsupported_compression, method}}
  end

  defp read_blocks(_fd, _offset, remaining, _max_bytes, _z, acc, _total) when remaining <= 0 do
    {:ok, IO.iodata_to_binary(acc)}
  end

  defp read_blocks(fd, offset, remaining, max_bytes, z, acc, total) do
    case :file.pread(fd, offset, min(@read_block_bytes, remaining)) do
      {:ok, block} ->
        case inflate_block(block, max_bytes, z, acc, total) do
          {:ok, acc, total} ->
            read_blocks(
              fd,
              offset + byte_size(block),
              remaining - byte_size(block),
              max_bytes,
              z,
              acc,
              total
            )

          {:error, _reason} = error ->
            error
        end

      :eof ->
        {:ok, IO.iodata_to_binary(acc)}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  defp inflate_block(<<>>, _max_bytes, _z, acc, total), do: {:ok, acc, total}

  defp inflate_block(block, max_bytes, z, acc, total) do
    {chunk, rest} = split_chunk(block)
    out = :zlib.inflate(z, chunk)
    total = total + IO.iodata_length(out)

    if total > max_bytes do
      {:error, :too_large}
    else
      inflate_block(rest, max_bytes, z, [acc, out], total)
    end
  end

  defp split_chunk(block) when byte_size(block) <= @inflate_chunk_bytes, do: {block, <<>>}

  defp split_chunk(<<chunk::binary-size(@inflate_chunk_bytes), rest::binary>>), do: {chunk, rest}

  # ---- Integrity -----------------------------------------------------------

  defp verify_crc(fd, header, comp_size, body) do
    with {:ok, expected} <- expected_crc(fd, header, comp_size) do
      case :erlang.crc32(body) do
        ^expected -> :ok
        _mismatch -> {:error, :bad_crc}
      end
    end
  end

  defp expected_crc(_fd, %{streamed?: false, crc: crc}, _comp_size), do: {:ok, crc}

  defp expected_crc(fd, %{streamed?: true, data_offset: data_offset}, comp_size) do
    case :file.pread(fd, data_offset + comp_size, @data_descriptor_bytes) do
      {:ok, <<@data_descriptor_signature::little-32, crc::little-32>>} -> {:ok, crc}
      {:ok, <<crc::little-32, _rest::binary>>} -> {:ok, crc}
      {:ok, _short} -> {:error, :bad_data_descriptor}
      :eof -> {:error, :bad_data_descriptor}
      {:error, reason} -> {:error, {:read_failed, reason}}
    end
  end
end
