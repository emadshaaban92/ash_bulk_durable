defmodule AshBulkDurable.Storage.S3ApiTest do
  @moduledoc """
  `AshBulkDurable.Storage.S3` against a real S3 API, so what the ETS stub
  in `s3_test.exs` assumes of S3 (a `404` for a missing key; `Content-Range`,
  an `ETag` and `If-Match` on a ranged `GET`; `416` for any range of an
  empty object; the `ListObjectsV2` XML and its pages; an `ETag` on each
  uploaded part) is checked against a store that is not ours.

  Excluded by default. CI runs it against RustFS, a MinIO-compatible
  server (MinIO no longer publishes its image on Docker Hub). Locally:

      docker run -d -p 9000:9000 rustfs/rustfs:1.0.4
      mix test --only s3

  `S3_TEST_ENDPOINT` (`http://localhost:9000`), `S3_TEST_ACCESS_KEY` and
  `S3_TEST_SECRET_KEY` (both `rustfsadmin`) point it at any other store
  speaking the S3 API: MinIO, a bucket on S3 itself, and so on.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Storage.S3
  alias AshBulkDurable.Test.S3HookedClient

  @moduletag :s3
  @moduletag :tmp_dir

  setup_all do
    endpoint = URI.parse(System.get_env("S3_TEST_ENDPOINT", "http://localhost:9000"))

    ex_aws = [
      http_client: S3HookedClient,
      scheme: "#{endpoint.scheme}://",
      host: endpoint.host,
      port: endpoint.port,
      access_key_id: System.get_env("S3_TEST_ACCESS_KEY", "rustfsadmin"),
      secret_access_key: System.get_env("S3_TEST_SECRET_KEY", "rustfsadmin"),
      region: "us-east-1",
      retries: [max_attempts: 1]
    ]

    bucket = "ash-bulk-durable-#{System.unique_integer([:positive])}"
    {:ok, _response} = bucket |> ExAws.S3.put_bucket("us-east-1") |> ExAws.request(ex_aws)

    %{bucket: bucket, ex_aws: ex_aws}
  end

  setup %{bucket: bucket, ex_aws: ex_aws, tmp_dir: tmp_dir} do
    on_exit(&S3HookedClient.clear/0)
    source = Path.join(tmp_dir, "source")
    File.write!(source, "the bytes")
    dest = Path.join(tmp_dir, "dest")
    File.write!(dest, "")

    %{
      dest: dest,
      opts: [bucket: bucket, ex_aws: ex_aws],
      prefix: "bulk-staging/#{System.unique_integer([:positive])}/",
      source: source
    }
  end

  test "a file round-trips a range at a time, under a key with spaces, + and non-ASCII letters",
       %{dest: dest, opts: opts, prefix: prefix, source: source} do
    key = prefix <> "a b+c/é & ü.zip"

    assert :ok = S3.put_file(key, source, opts)
    assert :ok = S3.fetch_file(key, dest, [chunk_size: 4] ++ opts)
    assert File.read!(dest) == "the bytes"
    assert {:ok, [%{key: ^key, last_modified: %DateTime{}}]} = S3.list_files(prefix, opts)
  end

  test "a file bigger than a part goes up in parts and comes back whole",
       %{dest: dest, opts: opts, prefix: prefix} = ctx do
    big = Path.join(ctx.tmp_dir, "big")
    bytes = :crypto.strong_rand_bytes(11 * 1024 * 1024)
    File.write!(big, bytes)

    assert :ok = S3.put_file(prefix <> "big", big, opts)
    assert :ok = S3.fetch_file(prefix <> "big", dest, opts)
    assert File.read!(dest) == bytes
  end

  test "an empty file round-trips", %{dest: dest, opts: opts, prefix: prefix} = ctx do
    empty = Path.join(ctx.tmp_dir, "empty")
    File.write!(empty, "")
    File.write!(dest, "left over")

    assert :ok = S3.put_file(prefix <> "empty", empty, opts)
    assert :ok = S3.fetch_file(prefix <> "empty", dest, opts)
    assert File.read!(dest) == ""
  end

  test "a missing key is :not_found", %{dest: dest, opts: opts, prefix: prefix} do
    assert {:error, :not_found} = S3.fetch_file(prefix <> "none", dest, opts)
  end

  test "an object replaced part way through a fetch fails it",
       %{bucket: bucket, dest: dest, ex_aws: ex_aws, opts: opts, prefix: prefix} do
    key = prefix <> "replaced"

    {:ok, _response} =
      bucket |> ExAws.S3.put_object(key, "first version") |> ExAws.request(ex_aws)

    # Between the first range, whose answer gives the ETag, and the second.
    S3HookedClient.before_each(fn
      :get, _url ->
        if Process.put(:s3_api_test_got, true) do
          S3HookedClient.clear()
          {:ok, _} = bucket |> ExAws.S3.put_object(key, "second version") |> ExAws.request(ex_aws)
        end

      _method, _url ->
        :ok
    end)

    assert {:error, {:http_error, 412, _response}} =
             S3.fetch_file(key, dest, [chunk_size: 4] ++ opts)
  end

  test "a deleted key is gone, and deleting it again is :ok",
       %{opts: opts, prefix: prefix, source: source} do
    :ok = S3.put_file(prefix <> "a", source, opts)

    assert :ok = S3.delete_file(prefix <> "a", opts)
    assert {:ok, []} = S3.list_files(prefix, opts)
    assert :ok = S3.delete_file(prefix <> "a", opts)
  end

  test "a listing longer than a page is read whole",
       %{bucket: bucket, ex_aws: ex_aws, opts: opts, prefix: prefix} do
    # S3 answers at most 1,000 keys a page.
    keys = for n <- 1..1001, do: prefix <> "#{n}"

    keys
    |> Task.async_stream(
      &(bucket |> ExAws.S3.put_object(&1, "x") |> ExAws.request(ex_aws)),
      max_concurrency: 32
    )
    |> Enum.each(fn {:ok, {:ok, _response}} -> :ok end)

    assert {:ok, files} = S3.list_files(prefix, opts)
    assert Enum.sort(Enum.map(files, & &1.key)) == Enum.sort(keys)
  end

  test "check_config/1 is :ok with hackney there", %{opts: opts} do
    assert :ok = S3.check_config(opts)
  end
end
