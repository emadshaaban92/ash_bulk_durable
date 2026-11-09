defmodule AshBulkDurable.Storage.S3Test do
  use ExUnit.Case, async: true

  alias AshBulkDurable.Storage.S3
  alias AshBulkDurable.Test.S3Stub

  @moduletag :tmp_dir

  @ex_aws [
    http_client: S3Stub,
    access_key_id: "test-key",
    secret_access_key: "test-secret",
    region: "us-east-1",
    retries: [max_attempts: 1]
  ]

  defmodule Extended do
    @moduledoc false
    use AshBulkDurable.Storage.S3

    @impl AshBulkDurable.Core.Storage
    def delete_file(_key, _opts), do: {:error, :kept}
  end

  defmodule OwnBucket do
    @moduledoc false
    use AshBulkDurable.Storage.S3,
      bucket: "own-bucket",
      ex_aws: [
        http_client: AshBulkDurable.Test.S3Stub,
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        retries: [max_attempts: 1]
      ]
  end

  # Runs `fun` once, just before the second `GET` of an object is answered:
  # between the first range and the next. The stub answers in the caller's
  # process, so the count lives there.
  defp after_first_get(bucket, fun) do
    S3Stub.before_each(bucket, fn
      {:get, key} when key != "" ->
        gets = Process.get(:s3_test_gets, 0) + 1
        Process.put(:s3_test_gets, gets)
        if gets == 2, do: fun.()

      _other ->
        :ok
    end)
  end

  setup %{tmp_dir: tmp_dir} do
    bucket = "bucket-#{System.unique_integer([:positive])}"
    source = Path.join(tmp_dir, "source")
    File.write!(source, "the bytes")
    dest = Path.join(tmp_dir, "dest")
    File.write!(dest, "")

    %{bucket: bucket, dest: dest, opts: [bucket: bucket, ex_aws: @ex_aws], source: source}
  end

  test "a file put under a key is fetched back to a path, a range at a time",
       %{bucket: bucket, dest: dest, opts: opts, source: source} do
    assert :ok = S3.put_file("bulk-staging/u/1/logo.zip", source, opts)
    assert S3Stub.get(bucket, "bulk-staging/u/1/logo.zip") == "the bytes"

    assert :ok = S3.fetch_file("bulk-staging/u/1/logo.zip", dest, [chunk_size: 4] ++ opts)
    assert File.read!(dest) == "the bytes"

    ranges =
      for {:get, _key, _query, headers} <- S3Stub.requests(bucket),
          do: {headers["range"], headers["if-match"] != nil}

    # The first range's answer gives the ETag the rest ask for.
    assert ranges == [{"bytes=0-3", false}, {"bytes=4-7", true}, {"bytes=8-8", true}]
  end

  test "a file bigger than a part is uploaded in parts and arrives whole",
       %{bucket: bucket, opts: opts} = ctx do
    big = Path.join(ctx.tmp_dir, "big")
    bytes = :crypto.strong_rand_bytes(11 * 1024 * 1024)
    File.write!(big, bytes)

    assert :ok = S3.put_file("bulk-staging/big", big, opts)
    assert S3Stub.get(bucket, "bulk-staging/big") == bytes

    parts = for {:put, _key, %{"partNumber" => n}, _headers} <- S3Stub.requests(bucket), do: n
    assert Enum.sort(parts) == ["1", "2", "3"]

    assert :ok = S3.fetch_file("bulk-staging/big", ctx.dest, opts)
    assert File.read!(ctx.dest) == bytes
  end

  test "a file of one part or less goes in a single PUT",
       %{bucket: bucket, opts: opts, source: source} do
    assert :ok = S3.put_file("bulk-staging/a", source, opts)

    assert [{:put, "bulk-staging/a", query, _headers}] = S3Stub.requests(bucket)
    assert query == %{}
  end

  test "a bigger :part_size sends a bigger file in one PUT, and one under 5 MiB is refused",
       %{bucket: bucket, opts: opts} = ctx do
    big = Path.join(ctx.tmp_dir, "big")
    File.write!(big, :binary.copy("x", 6 * 1024 * 1024))

    assert :ok = S3.put_file("bulk-staging/big", big, [part_size: 6 * 1024 * 1024] ++ opts)
    assert [{:put, "bulk-staging/big", query, _headers}] = S3Stub.requests(bucket)
    assert query == %{}

    assert_raise ArgumentError, ~r/`:part_size` must be an integer of at least/, fn ->
      S3.put_file("bulk-staging/big", big, [part_size: 1024] ++ opts)
    end
  end

  test "a part that fails aborts the upload and answers the error",
       %{bucket: bucket, opts: opts} = ctx do
    big = Path.join(ctx.tmp_dir, "big")
    File.write!(big, :binary.copy("x", 6 * 1024 * 1024))
    S3Stub.fail(bucket, 500, :put)

    assert {:error, {:http_error, 500, _}} = S3.put_file("bulk-staging/big", big, opts)
    assert S3Stub.keys(bucket) == []
    assert S3Stub.open_uploads(bucket) == []

    assert [{:delete, "bulk-staging/big", %{"uploadId" => _}, _headers}] =
             for({:delete, _, _, _} = request <- S3Stub.requests(bucket), do: request)
  end

  test "a part answered without its ETag aborts the upload",
       %{bucket: bucket, opts: opts} = ctx do
    big = Path.join(ctx.tmp_dir, "big")
    File.write!(big, :binary.copy("x", 6 * 1024 * 1024))
    S3Stub.misbehave(bucket, :no_part_etag)

    assert {:error, :no_etag} = S3.put_file("bulk-staging/big", big, opts)
    assert S3Stub.open_uploads(bucket) == []
  end

  test "an empty file round-trips, and a fetch empties what was at the path",
       %{bucket: bucket, dest: dest, opts: opts} = ctx do
    empty = Path.join(ctx.tmp_dir, "empty")
    File.write!(empty, "")
    File.write!(dest, "left over")

    assert :ok = S3.put_file("bulk-staging/empty", empty, opts)
    assert S3Stub.get(bucket, "bulk-staging/empty") == ""

    assert :ok = S3.fetch_file("bulk-staging/empty", dest, opts)
    assert File.read!(dest) == ""
  end

  test "a fetch replaces a longer file at the path", %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "short")
    File.write!(dest, "something much longer")

    assert :ok = S3.fetch_file("bulk-staging/a", dest, opts)
    assert File.read!(dest) == "short"
  end

  test "a missing key fails the fetch with :not_found", %{dest: dest, opts: opts} do
    assert {:error, :not_found} = S3.fetch_file("bulk-staging/none", dest, opts)
  end

  test "an object replaced part way through a fetch fails it",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "first version")

    after_first_get(bucket, fn -> S3Stub.put(bucket, "bulk-staging/a", "second version") end)

    assert {:error, {:http_error, 412, _response}} =
             S3.fetch_file("bulk-staging/a", dest, [chunk_size: 4] ++ opts)
  end

  test "a range that comes back short fails the fetch",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    S3Stub.misbehave(bucket, :short_reads)

    assert {:error, :length_mismatch} = S3.fetch_file("bulk-staging/a", dest, opts)
  end

  test "a range answered without its Content-Range fails the fetch",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    S3Stub.misbehave(bucket, :no_content_range)

    assert {:error, :no_content_range} = S3.fetch_file("bulk-staging/a", dest, opts)
  end

  test "a store that ignores Range sends the whole object at once, which is written",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    S3Stub.misbehave(bucket, :ignore_range)

    assert :ok = S3.fetch_file("bulk-staging/a", dest, [chunk_size: 4] ++ opts)
    assert File.read!(dest) == "the bytes"
  end

  test "a store that gives no ETag is fetched without If-Match",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    S3Stub.misbehave(bucket, :no_etag)

    assert :ok = S3.fetch_file("bulk-staging/a", dest, [chunk_size: 4] ++ opts)
    assert File.read!(dest) == "the bytes"
    refute Enum.any?(S3Stub.requests(bucket), fn {_, _, _, headers} -> headers["if-match"] end)
  end

  test "without an ETag, an object replaced by one of another size mid-fetch fails it",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    S3Stub.misbehave(bucket, :no_etag)
    after_first_get(bucket, fn -> S3Stub.put(bucket, "bulk-staging/a", "the longer bytes") end)

    assert {:error, :length_mismatch} =
             S3.fetch_file("bulk-staging/a", dest, [chunk_size: 4] ++ opts)
  end

  test "a later range answered 200 with the whole object fails the fetch",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    after_first_get(bucket, fn -> S3Stub.misbehave(bucket, :ignore_range) end)

    assert {:error, :length_mismatch} =
             S3.fetch_file("bulk-staging/a", dest, [chunk_size: 4] ++ opts)
  end

  test "a later range answered 416 fails the fetch",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    S3Stub.misbehave(bucket, :no_etag)
    after_first_get(bucket, fn -> S3Stub.put(bucket, "bulk-staging/a", "") end)

    assert {:error, {:http_error, 416, _response}} =
             S3.fetch_file("bulk-staging/a", dest, [chunk_size: 4] ++ opts)
  end

  test "a key deleted between two ranges is :not_found too",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "the bytes")
    after_first_get(bucket, fn -> :ets.delete(S3Stub, {:object, bucket, "bulk-staging/a"}) end)

    assert {:error, :not_found} = S3.fetch_file("bulk-staging/a", dest, [chunk_size: 4] ++ opts)
  end

  test "a store that answers with an error fails every call with it",
       %{bucket: bucket, dest: dest, opts: opts, source: source} do
    S3Stub.put(bucket, "bulk-staging/a", "bytes")
    S3Stub.fail(bucket, 403)

    assert {:error, {:http_error, 403, _}} = S3.fetch_file("bulk-staging/a", dest, opts)
    assert {:error, {:http_error, 403, _}} = S3.delete_file("bulk-staging/a", opts)
    assert {:error, {:http_error, 403, _}} = S3.list_files("bulk-staging/", opts)
    assert {:error, {:http_error, 403, _}} = S3.put_file("bulk-staging/b", source, opts)
  end

  test "a deleted key is gone, and deleting it again is :ok", %{bucket: bucket, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "bytes")

    assert :ok = S3.delete_file("bulk-staging/a", opts)
    assert S3Stub.keys(bucket) == []
    assert :ok = S3.delete_file("bulk-staging/a", opts)
  end

  test "listing a prefix reads every page, with each file's key and timestamp",
       %{bucket: bucket, opts: opts} do
    stamps =
      for n <- 1..5, into: %{} do
        key = "bulk-staging/u/#{n}/a.zip"
        stamp = DateTime.add(~U[2026-01-01 00:00:00.000Z], n, :hour)
        S3Stub.put(bucket, key, "bytes", stamp)
        {key, stamp}
      end

    S3Stub.put(bucket, "elsewhere/b.zip", "bytes")
    S3Stub.page_size(bucket, 2)

    assert {:ok, files} = S3.list_files("bulk-staging/", opts)
    assert Map.new(files, &{&1.key, &1.last_modified}) == stamps
    assert length(files) == 5

    lists = for {:get, "", %{"list-type" => "2"}, _headers} <- S3Stub.requests(bucket), do: 1
    assert length(lists) == 3
  end

  test "a listed timestamp that is not a date fails the listing", %{bucket: bucket, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "bytes")
    S3Stub.misbehave(bucket, :bad_stamps)

    assert {:error, {:unreadable_last_modified, "bulk-staging/a", "yesterday"}} =
             S3.list_files("bulk-staging/", opts)
  end

  test "listing a prefix nothing was put under is empty", %{opts: opts} do
    assert {:ok, []} = S3.list_files("bulk-staging/", opts)
  end

  test "a key with spaces, plus signs and non-ASCII letters round-trips",
       %{dest: dest, opts: opts, source: source} do
    key = "bulk-staging/u/a b+c/é & ü.zip"

    assert :ok = S3.put_file(key, source, opts)
    assert {:ok, [%{key: ^key}]} = S3.list_files("bulk-staging/", opts)
    assert :ok = S3.fetch_file(key, dest, opts)
    assert File.read!(dest) == "the bytes"
    assert :ok = S3.delete_file(key, opts)
    assert {:ok, []} = S3.list_files("bulk-staging/", opts)
  end

  test "a missing source fails the put without a request",
       %{bucket: bucket, opts: opts} = ctx do
    assert {:error, :enoent} = S3.put_file("bulk-staging/a", Path.join(ctx.tmp_dir, "none"), opts)
    assert S3Stub.requests(bucket) == []
  end

  test "a call without a bucket raises", %{source: source} do
    assert_raise ArgumentError, ~r/needs a `:bucket`/, fn ->
      S3.put_file("bulk-staging/a", source, bucket: "", ex_aws: @ex_aws)
    end
  end

  test "check_config/1 says whether a bucket is set and ExAws's HTTP client is there" do
    assert :ok = S3.check_config(bucket: "b", ex_aws: @ex_aws)

    assert {:error, message} = S3.check_config(bucket: "", ex_aws: @ex_aws)
    assert message =~ "needs a `:bucket`"

    # The suite has no `:req`.
    assert {:error, message} =
             S3.check_config(bucket: "b", ex_aws: [http_client: ExAws.Request.Req])

    assert message =~ "ExAws.Request.Req is not available; add `:req`"
  end

  test "a module that uses it gets the callbacks, and can override them",
       %{bucket: bucket, dest: dest, opts: opts} do
    S3Stub.put(bucket, "bulk-staging/a", "bytes")

    assert :ok = Extended.fetch_file("bulk-staging/a", dest, opts)
    assert {:ok, [%{key: "bulk-staging/a"}]} = Extended.list_files("bulk-staging/", opts)
    assert {:error, :kept} = Extended.delete_file("bulk-staging/a", opts)
  end

  test "options given to use reach every delegated call, under the call's own",
       %{bucket: bucket, dest: dest, source: source} do
    key = "bulk-staging/own-#{System.unique_integer([:positive])}"

    assert :ok = OwnBucket.check_config([])
    assert :ok = OwnBucket.put_file(key, source, [])
    assert S3Stub.get("own-bucket", key) == "the bytes"
    assert {:ok, files} = OwnBucket.list_files("bulk-staging/", [])
    assert key in Enum.map(files, & &1.key)
    assert :ok = OwnBucket.fetch_file(key, dest, [])
    assert :ok = OwnBucket.delete_file(key, [])
    assert S3Stub.get("own-bucket", key) == nil

    assert :ok = OwnBucket.put_file("bulk-staging/b", source, bucket: bucket)
    assert S3Stub.get(bucket, "bulk-staging/b") == "the bytes"
  end
end

defmodule AshBulkDurable.Storage.S3ConfigTest do
  # Sets the store's application config, so it runs alone.
  use ExUnit.Case, async: false

  alias AshBulkDurable.Storage.S3
  alias AshBulkDurable.Test.S3Stub

  test "the bucket and ExAws overrides come from config when opts leave them out" do
    previous = Application.get_env(:ash_bulk_durable, S3)
    bucket = "config-bucket-#{System.unique_integer([:positive])}"

    Application.put_env(:ash_bulk_durable, S3,
      bucket: bucket,
      ex_aws: [
        http_client: S3Stub,
        access_key_id: "test-key",
        secret_access_key: "test-secret",
        retries: [max_attempts: 1]
      ]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_bulk_durable, S3, previous),
        else: Application.delete_env(:ash_bulk_durable, S3)
    end)

    assert :ok = S3.check_config()
    S3Stub.put(bucket, "bulk-staging/a", "bytes")
    assert {:ok, [%{key: "bulk-staging/a"}]} = S3.list_files("bulk-staging/")

    # A call's `:ex_aws` keys merge over the configured ones, keeping the
    # stub client and credentials.
    assert {:ok, [%{key: "bulk-staging/a"}]} =
             S3.list_files("bulk-staging/", ex_aws: [region: "eu-west-1"])

    Application.delete_env(:ash_bulk_durable, S3)
    assert {:error, _message} = S3.check_config()
  end
end
