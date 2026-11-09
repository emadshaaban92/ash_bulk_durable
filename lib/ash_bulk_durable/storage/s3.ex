if Code.ensure_loaded?(ExAws.S3) and Code.ensure_loaded?(SweetXml) do
  defmodule AshBulkDurable.Storage.S3 do
    @moduledoc """
    An `AshBulkDurable.Core.Storage` that keeps staged files in an S3 bucket,
    or in any store that speaks the S3 API (MinIO, R2, and the like), through
    `ExAws`.

    Every node reads the same bucket, so it suits an application on any
    number of nodes.

    ## Setting it up

    It is compiled only when the application depends on `ExAws`'s S3 client
    and the XML parser it reads listings with, and on an HTTP client `ExAws`
    supports: `:hackney`, its default, or `:req` with
    `config :ex_aws, http_client: ExAws.Request.Req`.

        {:ex_aws, "~> 2.7"},
        {:ex_aws_s3, "~> 2.5"},
        {:sweet_xml, "~> 0.7"},
        # The version ex_aws 2.7 asks for.
        {:hackney, "~> 4.0"}

    Then:

        config :ash_bulk_durable, storage: AshBulkDurable.Storage.S3

        config :ash_bulk_durable, AshBulkDurable.Storage.S3,
          bucket: "my-app-bulk-files"

    Credentials, region and endpoint are `ExAws`'s own configuration
    (`config :ex_aws, ...`), so an application already using `ExAws` sets
    nothing more. The credentials need `s3:GetObject`, `s3:PutObject`,
    `s3:DeleteObject`, `s3:AbortMultipartUpload` and `s3:ListBucket` on the
    bucket. Without `s3:ListBucket` the sweep cannot list, and S3 answers a
    missing key with `403` rather than `404`, so a fetch of one fails with
    that error instead of `:not_found`.

    Options, read when they are used, so `config/runtime.exs` can set them:

      * `:bucket` — the bucket files are staged in. Required.
      * `:ex_aws` — overrides for every request this store makes, as
        `ExAws.request/2` takes them (`region:`, `host:`, `http_client:`,
        credentials...), for a bucket that needs other settings than the rest
        of the application's `ExAws` calls. Its keys merge over the configured
        `:ex_aws` ones, one by one, rather than replacing the list.
      * `:chunk_size` — how many bytes `fetch_file/3` asks for at a time,
        8 MiB by default. A fetch holds one chunk in memory, never the file.
      * `:part_size` — the size of the parts `put_file/3` uploads a bigger
        file in, and of the biggest file it sends in one `PUT`. 5 MiB by
        default, which is also S3's least. S3 takes at most 10,000 parts, so
        the default caps a file at about 48.8 GiB; a bigger part size raises
        the cap and sends fewer requests.

    Every callback and function here also takes them in its `opts`, over the
    configured ones.

    No request this store makes runs in another process, so a slow or failing
    store answers `{:error, term}` (after `ExAws`'s own retries) instead of
    taking the caller down.

    ## Staging a file

    The engine only fetches, deletes and lists. Putting a file there is the
    host's: `put_file/3` uploads a file the server holds, and a browser can
    upload straight to the bucket with a presigned `PUT`
    (`ExAws.S3.presigned_url/5`) for the key the bulk action names.

    ## Fetching

    `fetch_file/3` fetches the object in ranges. The first one's answer
    gives its size and ETag, and every later range asks for that ETag, so an
    object replaced mid-fetch fails the fetch rather than writing half of
    each. A store that gives no ETag is fetched without it. Then an object
    replaced by one of another size still fails the fetch (a later range
    reports a size other than the first one's, as `{:error,
    :length_mismatch}`), but one replaced by another of the same size is not
    caught. A missing key is `{:error, :not_found}`.

    ## What is left in the bucket

    A `put_file/3` whose upload fails aborts it, but one whose process dies
    part way through a file bigger than one part leaves an incomplete
    multipart upload, which S3 keeps (and bills) until it is aborted. A
    lifecycle rule that aborts incomplete multipart uploads after a day
    clears them. Files under the staging prefix that no bulk action holds
    are deleted by the daily sweep; nothing deletes files outside it.

    ## Adding to it

    A host that wants more of its store than the engine needs (presigned
    links for a browser, say) writes a module of its own and points
    `:storage` at that:

        defmodule MyApp.BulkActions.Storage do
          use AshBulkDurable.Storage.S3

          def presigned_put_url(key, opts), do: ...
        end

    `use` delegates `fetch_file/3`, `delete_file/2`, `list_files/2`,
    `check_config/1` and `put_file/3` here, each of them overridable.
    Options given to `use` (`use AshBulkDurable.Storage.S3, bucket: ...`) go
    to each of them, under the ones a call passes. They are read when the
    host module compiles, so a `:bucket` that `config/runtime.exs` sets
    belongs in config, not in `use`. The injected `put_file/3` takes its
    `opts` without a default; override it the same way.
    """
    @behaviour AshBulkDurable.Core.Storage

    @default_chunk_size 8 * 1024 * 1024

    # S3's smallest part, but for the last one.
    @min_part_size 5 * 1024 * 1024

    @doc false
    defmacro __using__(use_opts) do
      quote do
        @behaviour AshBulkDurable.Core.Storage

        @ash_bulk_durable_s3_opts unquote(use_opts)

        @impl AshBulkDurable.Core.Storage
        def fetch_file(key, path, opts),
          do: AshBulkDurable.Storage.S3.fetch_file(key, path, __ash_bulk_durable_s3_opts__(opts))

        @impl AshBulkDurable.Core.Storage
        def delete_file(key, opts),
          do: AshBulkDurable.Storage.S3.delete_file(key, __ash_bulk_durable_s3_opts__(opts))

        @impl AshBulkDurable.Core.Storage
        def list_files(prefix, opts),
          do: AshBulkDurable.Storage.S3.list_files(prefix, __ash_bulk_durable_s3_opts__(opts))

        @impl AshBulkDurable.Core.Storage
        def check_config(opts),
          do: AshBulkDurable.Storage.S3.check_config(__ash_bulk_durable_s3_opts__(opts))

        @doc "Uploads `source` under `key`; see `AshBulkDurable.Storage.S3.put_file/3`."
        def put_file(key, source, opts),
          do: AshBulkDurable.Storage.S3.put_file(key, source, __ash_bulk_durable_s3_opts__(opts))

        defp __ash_bulk_durable_s3_opts__(opts),
          do: AshBulkDurable.Storage.S3.merge_options(@ash_bulk_durable_s3_opts, opts)

        defoverridable fetch_file: 3, delete_file: 2, list_files: 2, check_config: 1, put_file: 3
      end
    end

    @impl true
    def fetch_file(key, path, opts \\ []) do
      opts = options(opts)
      bucket = bucket(opts)

      with {:ok, file} <- File.open(path, [:write, :binary]) do
        try do
          fetch_ranges(file, {bucket, key, nil}, {0, nil}, opts)
        after
          File.close(file)
        end
      end
    end

    # One range at a time, so a fetch holds one chunk, whatever the file's
    # size. The first range's answer gives the object's size (its
    # `Content-Range`) and ETag, which every later range asks for. There is
    # no `HEAD`: `ExAws`'s hackney client cannot read hackney 4's answer to
    # one. The open above already emptied the file, so an empty object (which
    # S3 answers any range of with `416`) needs nothing written.
    defp fetch_ranges(_file, _object, {from, size}, _opts) when is_integer(size) and from >= size,
      do: :ok

    defp fetch_ranges(file, {bucket, key, etag}, {from, size}, opts) do
      to = from + chunk_size(opts) - 1
      to = if size, do: min(to, size - 1), else: to
      range = [range: "bytes=#{from}-#{to}"] ++ if(etag, do: [if_match: etag], else: [])

      case fetch_request(ExAws.S3.get_object(bucket, key, range), opts) do
        {:ok, %{status_code: 206, headers: headers, body: body}} ->
          with {:ok, total} <- total_size(headers),
               :ok <- check_total(total, size),
               :ok <- check_length(body, min(to, total - 1) - from + 1),
               :ok <- IO.binwrite(file, body) do
            object = {bucket, key, etag || header(headers, "etag")}
            fetch_ranges(file, object, {from + byte_size(body), total}, opts)
          end

        # A store that ignored `Range` and sent the whole object, which is
        # only that when nothing has been fetched before it.
        {:ok, %{status_code: 200, body: body}} when from == 0 ->
          IO.binwrite(file, body)

        {:ok, %{status_code: 200}} ->
          {:error, :length_mismatch}

        {:error, {:http_error, 416, _response}} when from == 0 ->
          :ok

        answer ->
          unexpected(answer)
      end
    end

    # Every range after the first must report the size the first one did:
    # without an ETag, that is what catches an object replaced mid-fetch by
    # one of another size.
    defp check_total(_total, nil), do: :ok
    defp check_total(size, size), do: :ok
    defp check_total(_total, _size), do: {:error, :length_mismatch}

    defp total_size(headers) do
      with "bytes " <> range when is_binary(range) <- header(headers, "content-range"),
           [_range, total] <- String.split(range, "/"),
           {total, ""} when total > 0 <- Integer.parse(total) do
        {:ok, total}
      else
        _missing -> {:error, :no_content_range}
      end
    end

    # Shorter, or longer (a store that ignored `Range` and sent it all).
    defp check_length(body, expected) when byte_size(body) == expected, do: :ok
    defp check_length(_body, _expected), do: {:error, :length_mismatch}

    @impl true
    def delete_file(key, opts \\ []) do
      opts = options(opts)

      case request(ExAws.S3.delete_object(bucket(opts), key), opts) do
        {:ok, _response} -> :ok
        {:error, _reason} = error -> error
      end
    end

    @impl true
    def list_files(prefix, opts \\ []) do
      opts = options(opts)
      list_pages(bucket(opts), prefix, nil, [], opts)
    end

    defp list_pages(bucket, prefix, token, pages, opts) do
      page_opts = [prefix: prefix] ++ if(token, do: [continuation_token: token], else: [])

      with {:ok, %{body: body}} <- request(ExAws.S3.list_objects_v2(bucket, page_opts), opts),
           {:ok, files} <- listed_files(body) do
        pages = [files | pages]

        case body do
          %{is_truncated: "true", next_continuation_token: next} when next not in [nil, ""] ->
            list_pages(bucket, prefix, next, pages, opts)

          _last_page ->
            {:ok, pages |> Enum.reverse() |> Enum.concat()}
        end
      else
        answer -> unexpected(answer)
      end
    end

    # A file whose timestamp cannot be read fails the listing rather than
    # dropping out of it. The sweep logs a failed listing and deletes nothing
    # that day, so a file it cannot age is never deleted early, and the
    # warning says why nothing is reclaimed.
    defp listed_files(%{contents: contents}) do
      Enum.reduce_while(contents, {:ok, []}, fn %{key: key, last_modified: stamp}, {:ok, files} ->
        case DateTime.from_iso8601(stamp) do
          {:ok, last_modified, _offset} ->
            {:cont, {:ok, [%{key: key, last_modified: last_modified} | files]}}

          {:error, _reason} ->
            {:halt, {:error, {:unreadable_last_modified, key, stamp}}}
        end
      end)
      |> case do
        {:ok, files} -> {:ok, Enum.reverse(files)}
        error -> error
      end
    end

    defp listed_files(body), do: {:error, {:unreadable_listing, body}}

    @doc """
    Uploads the local file at `source` under `key`. A file of up to
    `:part_size` (5 MiB by default) goes in one `PUT`; a bigger one in parts
    of that size, one at a time, so it is never held in memory whole, and an
    upload that fails is aborted. An object appears under `key` only once
    all of it is in.
    """
    @spec put_file(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
    def put_file(key, source, opts \\ []) do
      opts = options(opts)
      bucket = bucket(opts)
      part_size = part_size(opts)

      case File.stat(source) do
        {:ok, %File.Stat{type: :regular, size: size}} when size <= part_size ->
          with {:ok, body} <- File.read(source),
               {:ok, _response} <- request(ExAws.S3.put_object(bucket, key, body), opts),
               do: :ok

        {:ok, %File.Stat{type: :regular}} ->
          with {:ok, file} <- File.open(source, [:read, :binary]) do
            try do
              put_in_parts(file, bucket, key, part_size, opts)
            after
              File.close(file)
            end
          end

        {:ok, %File.Stat{type: type}} ->
          {:error, {:not_a_file, type}}

        {:error, _reason} = error ->
          error
      end
    end

    # `ExAws.S3.Upload` sends parts from linked tasks with a timeout, so a
    # slow part would kill the caller; these go one by one from here.
    defp put_in_parts(file, bucket, key, part_size, opts) do
      case request(ExAws.S3.initiate_multipart_upload(bucket, key), opts) do
        {:ok, %{body: %{upload_id: upload_id}}} when is_binary(upload_id) ->
          with {:ok, parts} <- put_parts(file, {bucket, key, upload_id, part_size}, {1, []}, opts),
               {:ok, _response} <-
                 request(ExAws.S3.complete_multipart_upload(bucket, key, upload_id, parts), opts) do
            :ok
          else
            error ->
              _ = request(ExAws.S3.abort_multipart_upload(bucket, key, upload_id), opts)
              error
          end

        {:ok, response} ->
          {:error, {:no_upload_id, response}}

        {:error, _reason} = error ->
          error
      end
    end

    defp put_parts(file, {bucket, key, upload_id, part_size} = upload, {number, parts}, opts) do
      case IO.binread(file, part_size) do
        :eof ->
          {:ok, Enum.reverse(parts)}

        {:error, _reason} = error ->
          error

        chunk ->
          part = ExAws.S3.upload_part(bucket, key, upload_id, number, chunk)

          with {:ok, %{headers: headers}} <- request(part, opts),
               etag when is_binary(etag) <- header(headers, "etag") || {:error, :no_etag} do
            put_parts(file, upload, {number + 1, [{number, etag} | parts]}, opts)
          else
            answer -> unexpected(answer)
          end
      end
    end

    @impl true
    @doc """
    `:ok` when a `:bucket` is configured (or given in `opts`) and `ExAws`'s
    HTTP client is loaded, so a node missing either fails when its poller
    starts rather than at its first fetch or sweep. It makes no request, so
    credentials and the bucket's existence are left to the first one.
    """
    def check_config(opts \\ []) do
      opts = options(opts)
      _bucket = bucket(opts)
      client = ExAws.Config.http_config(:s3, Keyword.get(opts, :ex_aws, [])).http_client

      if Code.ensure_loaded?(client) do
        :ok
      else
        {:error,
         "ExAws's HTTP client #{inspect(client)} is not available; add " <>
           "#{client_dep(client)} to the application's deps, or set " <>
           "`config :ex_aws, http_client: ...`"}
      end
    rescue
      error in ArgumentError -> {:error, Exception.message(error)}
    end

    defp request(operation, opts), do: ExAws.request(operation, Keyword.get(opts, :ex_aws, []))

    # A key that is gone, whether at the first range or between two, is
    # the same `:not_found`. Only a fetch reads a 404 so: elsewhere it is a
    # missing bucket, which must not pass for a missing key.
    defp fetch_request(operation, opts) do
      case request(operation, opts) do
        {:error, {:http_error, 404, _response}} -> {:error, :not_found}
        answer -> answer
      end
    end

    # An answer of a shape the caller did not expect is an error too, so
    # every callback answers `:ok` or `{:ok, _}` of its own, or `{:error, _}`.
    defp unexpected({:ok, response}), do: {:error, {:unexpected_response, response}}
    defp unexpected({:error, _reason} = error), do: error

    defp client_dep(ExAws.Request.Hackney), do: "`:hackney`"
    defp client_dep(ExAws.Request.Req), do: "`:req`"
    defp client_dep(_client), do: "the client's dependency"

    defp header(headers, name) do
      Enum.find_value(headers, fn {key, value} ->
        if String.downcase(key) == name, do: value
      end)
    end

    defp options(opts) do
      :ash_bulk_durable
      |> Application.get_env(__MODULE__, [])
      |> merge_options(opts)
    end

    @doc false
    # `opts` over `base`, with `:ex_aws` merged key by key rather than
    # replaced, so a call's `region:` keeps the configured credentials.
    def merge_options(base, opts) do
      Keyword.merge(base, opts, fn
        :ex_aws, base_ex_aws, ex_aws -> Keyword.merge(base_ex_aws, ex_aws)
        _key, _base_value, value -> value
      end)
    end

    defp chunk_size(opts) do
      case Keyword.get(opts, :chunk_size, @default_chunk_size) do
        size when is_integer(size) and size > 0 ->
          size

        other ->
          raise ArgumentError,
                "AshBulkDurable.Storage.S3's `:chunk_size` must be a positive integer, " <>
                  "got: #{inspect(other)}"
      end
    end

    defp part_size(opts) do
      case Keyword.get(opts, :part_size, @min_part_size) do
        size when is_integer(size) and size >= @min_part_size ->
          size

        other ->
          raise ArgumentError,
                "AshBulkDurable.Storage.S3's `:part_size` must be an integer of at least " <>
                  "#{@min_part_size} (5 MiB, S3's least), got: #{inspect(other)}"
      end
    end

    defp bucket(opts) do
      case Keyword.get(opts, :bucket) do
        bucket when is_binary(bucket) and bucket != "" ->
          bucket

        _missing ->
          raise ArgumentError, """
          AshBulkDurable.Storage.S3 needs a `:bucket`:

              config :ash_bulk_durable, AshBulkDurable.Storage.S3, bucket: "my-app-bulk-files"
          """
      end
    end
  end
end
