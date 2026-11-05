defmodule AshBulkDurable.Sheet.BoundedZipTest do
  @moduledoc """
  Bounds on companion-ZIP extraction.

  The threat is a user's archive that expands far beyond what it costs to upload.
  Every bomb here is built incrementally through a reused 1 MB buffer, so
  the test process never holds the expanded size — a test that materialised the
  payload it is guarding against would be the bug it is testing for.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Sheet.BoundedZip

  @mb 1024 * 1024

  defp write_zip(entries) do
    {:ok, path} = Briefly.create(extname: ".zip")
    File.rm!(path)
    charlists = Enum.map(entries, fn {name, body} -> {String.to_charlist(name), body} end)
    {:ok, _} = :zip.create(String.to_charlist(path), charlists)
    path
  end

  # A real, well-formed ZIP whose single entry declares and delivers
  # `decompressed_mb` of zeros from a ~1000:1 compressed stream. Deflated a
  # chunk at a time so nothing here ever holds the expanded bytes.
  defp write_bomb(decompressed_mb, opts \\ []) do
    chunk = :binary.copy(<<0>>, @mb)

    z = :zlib.open()
    :zlib.deflateInit(z, :best_compression, :deflated, -15, 9, :default)

    {iodata, crc, usize} =
      Enum.reduce(1..decompressed_mb, {[], 0, 0}, fn _, {acc, crc, size} ->
        {[acc, :zlib.deflate(z, chunk)], :erlang.crc32(crc, chunk), size + @mb}
      end)

    compressed = IO.iodata_to_binary([iodata, :zlib.deflate(z, <<>>, :finish)])
    :zlib.deflateEnd(z)
    :zlib.close(z)

    name = "zeros.bin"
    nlen = byte_size(name)
    csize = byte_size(compressed)
    # A lying archive understates the uncompressed size in both headers while
    # still shipping the full stream.
    declared = Keyword.get(opts, :declare, usize)

    local =
      <<0x04034B50::little-32, 20::little-16, 0::little-16, 8::little-16, 0::little-16,
        0::little-16, crc::little-32, csize::little-32, declared::little-32, nlen::little-16,
        0::little-16>> <> name

    central =
      <<0x02014B50::little-32, 20::little-16, 20::little-16, 0::little-16, 8::little-16,
        0::little-16, 0::little-16, crc::little-32, csize::little-32, declared::little-32,
        nlen::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32,
        0::little-32>> <> name

    cd_offset = byte_size(local) + csize

    eocd =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, 1::little-16, 1::little-16,
        byte_size(central)::little-32, cd_offset::little-32, 0::little-16>>

    {:ok, path} = Briefly.create(extname: ".zip")
    File.write!(path, local <> compressed <> central <> eocd)
    {path, byte_size(local <> compressed <> central <> eocd)}
  end

  # A hand-rolled single-entry archive, so the fields the reader trusts — the
  # CRC, the compressed size, the streaming flag — can each be set apart from
  # the bytes actually shipped. `:zip.create/2` only ever writes consistent
  # ones.
  defp write_entry(body, opts) do
    z = :zlib.open()
    :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    comp = IO.iodata_to_binary([:zlib.deflate(z, body), :zlib.deflate(z, <<>>, :finish)])
    :zlib.deflateEnd(z)
    :zlib.close(z)

    shipped =
      case Keyword.get(opts, :truncate) do
        :half -> binary_part(comp, 0, div(byte_size(comp), 2))
        nil -> comp
      end

    name = "a.bin"
    nlen = byte_size(name)
    usize = byte_size(body)
    csize = byte_size(shipped)
    crc = Keyword.get(opts, :crc, :erlang.crc32(body))
    streamed? = Keyword.get(opts, :streamed?, false)

    # A streaming writer zeroes the local header's CRC and sizes and writes
    # them into a descriptor after the data instead.
    {flags, local_crc, descriptor} =
      if streamed? do
        {0x08, 0, <<0x08074B50::little-32, crc::little-32, csize::little-32, usize::little-32>>}
      else
        {0x00, crc, <<>>}
      end

    local =
      <<0x04034B50::little-32, 20::little-16, flags::little-16, 8::little-16, 0::little-16,
        0::little-16, local_crc::little-32, csize::little-32, usize::little-32, nlen::little-16,
        0::little-16>> <> name

    central =
      <<0x02014B50::little-32, 20::little-16, 20::little-16, flags::little-16, 8::little-16,
        0::little-16, 0::little-16, crc::little-32, csize::little-32, usize::little-32,
        nlen::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-16, 0::little-32,
        0::little-32>> <> name

    cd_offset = byte_size(local) + csize + byte_size(descriptor)

    eocd =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, 1::little-16, 1::little-16,
        byte_size(central)::little-32, cd_offset::little-32, 0::little-16>>

    {:ok, path} = Briefly.create(extname: ".zip")
    File.write!(path, local <> shipped <> descriptor <> central <> eocd)
    path
  end

  # What one process holds, rather than `:erlang.memory(:total)` — the VM-wide
  # figure moves with whatever else the suite is running and says nothing about
  # this extraction. Inflated output is refc binary data, which lives off the
  # process heap and so has to be summed separately (and de-duplicated: a
  # binary referenced twice is listed twice).
  defp held_bytes(pid) do
    case :erlang.process_info(pid, [:binary, :memory]) do
      [{:binary, binaries}, {:memory, heap}] ->
        binaries
        |> Enum.uniq_by(fn {ref, _size, _count} -> ref end)
        |> Enum.reduce(heap, fn {_ref, size, _count}, total -> total + size end)

      :undefined ->
        0
    end
  end

  # Samples `pid` without sleeping between polls: the whole extraction is a
  # couple of milliseconds, so a poll that waits would take one sample and
  # could miss the peak entirely. Bounded by a deadline rather than an
  # iteration count — how many polls fit in an extraction depends on what else
  # the suite is running, and a count that bulk actions out mid-extraction fails the
  # test on something other than the memory bound.
  defp sample_until_done(task, pid, peak \\ 0, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 30_000

    case Task.yield(task, 0) do
      {:ok, result} ->
        {result, max(peak, held_bytes(pid))}

      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("extraction did not finish within 30s")
        end

        sample_until_done(task, pid, max(peak, held_bytes(pid)), deadline)
    end
  end

  describe "honest archives" do
    test "extracts an entry that fits the budget, byte for byte" do
      path = write_zip([{"a.jpg", "hello world"}])
      {:ok, state} = BoundedZip.open(path)

      assert {:ok, "hello world"} = BoundedZip.extract(state, state.index["a.jpg"], 10 * @mb)
      assert :ok = BoundedZip.close(state)
    end

    test "extracts a multi-megabyte entry unchanged when it is under budget" do
      body = :binary.copy("A", 3 * @mb)
      path = write_zip([{"big.bin", body}])
      {:ok, state} = BoundedZip.open(path)

      assert {:ok, extracted} = BoundedZip.extract(state, state.index["big.bin"], 10 * @mb)
      assert byte_size(extracted) == 3 * @mb
      assert extracted == body
      assert :ok = BoundedZip.close(state)
    end

    test "indexes by basename so subfolders stay out of the CSV" do
      path = write_zip([{"a.jpg", "x"}, {"sub/b.png", "y"}])
      {:ok, state} = BoundedZip.open(path)

      assert state.index["b.png"].name == "sub/b.png"
      assert :ok = BoundedZip.close(state)
    end

    test "rejects two entries sharing a basename, before any row runs" do
      path = write_zip([{"one/a.jpg", "x"}, {"two/a.jpg", "y"}])
      assert {:error, {:duplicate_basename, "a.jpg"}} = BoundedZip.open(path)
    end

    test "an unreadable path is an open failure, not a malformed archive" do
      assert {:error, {:zip_open_failed, :enoent}} =
               BoundedZip.open("/nonexistent-#{System.unique_integer([:positive])}.zip")
    end
  end

  describe "integrity" do
    test "an entry whose bytes don't match the recorded CRC is refused, not uploaded" do
      path = write_entry("hello world hello world", crc: 0xDEADBEEF)
      {:ok, state} = BoundedZip.open(path)

      assert {:error, :bad_crc} = BoundedZip.extract(state, state.index["a.bin"], 10 * @mb)
      assert :ok = BoundedZip.close(state)
    end

    # A stream that stops early inflates without complaint and yields a short
    # body — nothing but the CRC distinguishes it from a complete entry.
    test "a truncated stream is refused rather than returned short" do
      body = :crypto.strong_rand_bytes(200_000)
      path = write_entry(body, truncate: :half)
      {:ok, state} = BoundedZip.open(path)

      assert {:error, :bad_crc} = BoundedZip.extract(state, state.index["a.bin"], 10 * @mb)
      assert :ok = BoundedZip.close(state)
    end

    # A streaming writer emits an entry before it knows the entry's size, so
    # the CRC lands in a descriptor after the data and the local header's copy
    # is zeroed. Verifying against the zeroed copy would reject every archive
    # written that way.
    test "an entry whose CRC lives in a trailing data descriptor verifies against it" do
      body = :binary.copy("streamed bytes ", 1000)
      path = write_entry(body, streamed?: true)
      {:ok, state} = BoundedZip.open(path)

      assert {:ok, ^body} = BoundedZip.extract(state, state.index["a.bin"], 10 * @mb)
      assert :ok = BoundedZip.close(state)
    end

    test "a streamed entry is still refused when its descriptor CRC doesn't match" do
      body = :binary.copy("streamed bytes ", 1000)
      path = write_entry(body, streamed?: true, crc: 0xDEADBEEF)
      {:ok, state} = BoundedZip.open(path)

      assert {:error, :bad_crc} = BoundedZip.extract(state, state.index["a.bin"], 10 * @mb)
      assert :ok = BoundedZip.close(state)
    end
  end

  describe "zip bombs" do
    test "refuses an entry that honestly declares more than the budget, inflating nothing" do
      {path, wire} = write_bomb(200)
      {:ok, state} = BoundedZip.open(path)

      assert wire < 1 * @mb, "200 MB should compress to well under 1 MB"
      assert BoundedZip.declared_size(state.index["zeros.bin"]) == 200 * @mb

      assert {:error, {:too_large, declared}} =
               BoundedZip.extract(state, state.index["zeros.bin"], 10 * @mb)

      assert declared == 200 * @mb
      assert :ok = BoundedZip.close(state)
    end

    # The declared size is attacker-controlled and `:zip.zip_get/2` does not stop
    # at it, so a pre-check alone is bypassable. This is the case that proves the
    # budget is enforced during inflation rather than from the header.
    test "refuses an archive that lies about its size and ships the full stream" do
      {path, _wire} = write_bomb(200, declare: 1024)
      {:ok, state} = BoundedZip.open(path)

      # The archive claims 1 KB.
      assert BoundedZip.declared_size(state.index["zeros.bin"]) == 1024

      # It still cannot deliver 200 MB through a 10 MB budget.
      assert {:error, :too_large} =
               BoundedZip.extract(state, state.index["zeros.bin"], 10 * @mb)

      assert :ok = BoundedZip.close(state)
    end

    test "peak memory stays near the budget rather than the expanded size" do
      {path, _wire} = write_bomb(200, declare: 1024)
      {:ok, state} = BoundedZip.open(path)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, {:extracting, self()})
          BoundedZip.extract(state, state.index["zeros.bin"], 10 * @mb)
        end)

      assert_receive {:extracting, pid}

      {result, peak_bytes} = sample_until_done(task, pid)

      assert {:error, :too_large} = result

      # The bound admits the 10 MB budget, one chunk's expansion (~4 MB) and one
      # 256 KB disk block. 200 MB lands here with no bound at all, ~64 MB if the
      # inflate chunk grows to 64 KB — both well clear of this ceiling.
      assert peak_bytes < 24 * @mb,
             "extracting process held #{div(peak_bytes, @mb)} MB — the bound did not hold"

      assert :ok = BoundedZip.close(state)
    end
  end
end
