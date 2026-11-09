defmodule AshBulkDurable.Test.S3Stub do
  @moduledoc """
  A bucket in ETS, standing in for S3 at the HTTP layer, so
  `AshBulkDurable.Storage.S3` is driven through `ExAws` as it would be
  against a real store.

  Handed to a request as `ex_aws: [http_client: AshBulkDurable.Test.S3Stub]`,
  never configured globally, so nothing else in the suite talks to it. Each
  test names a bucket of its own, so the suite stays async. Every request is
  recorded under its bucket for `requests/1`.

  Answers what the store sends: `HEAD`, ranged `GET` (with `If-Match`),
  `DELETE`, `ListObjectsV2` paged by `page_size/2`, and the three requests
  of a multipart upload (and its abort). `fail/3`, `misbehave/2` and
  `before_each/2` make it misbehave.
  """

  @behaviour ExAws.Request.HttpClient

  @table __MODULE__

  @doc "Starts the table. Called once from `test_helper.exs`."
  def start do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ok
  end

  @doc "Puts `body` at `key` in `bucket`, as an earlier upload would have."
  def put(bucket, key, body, last_modified \\ DateTime.utc_now()) do
    etag = ~s("#{:erlang.phash2({body, System.unique_integer()})}")
    :ets.insert(@table, {{:object, bucket, key}, {body, etag, last_modified}})
    :ok
  end

  @doc "The body stored at `key`, or nil."
  def get(bucket, key) do
    case :ets.lookup(@table, {:object, bucket, key}) do
      [] -> nil
      [{_key, {body, _etag, _last_modified}}] -> body
    end
  end

  @doc "The multipart uploads started in `bucket` and neither completed nor aborted."
  def open_uploads(bucket), do: :ets.match(@table, {{:upload, bucket, :"$1", :_}, :_})

  @doc "Every key in `bucket`, sorted."
  def keys(bucket) do
    @table
    |> :ets.match({{:object, bucket, :"$1"}, :_})
    |> List.flatten()
    |> Enum.sort()
  end

  @doc "Every request made against `bucket`, oldest first, as `{method, key, query, headers}`."
  def requests(bucket) do
    @table
    |> :ets.match({{:request, bucket, :"$1"}, :"$2"})
    |> Enum.sort()
    |> Enum.map(fn [_order, request] -> request end)
  end

  @doc "Makes every request against `bucket` fail with `status`, or only those with `method`."
  def fail(bucket, status, method \\ :any),
    do: :ets.insert(@table, {{:failing, bucket}, {status, method}})

  @doc """
  Makes `bucket` answer wrongly, or as some stores do, in one way:
  `:short_reads` (a ranged `GET` one byte short), `:ignore_range` (a ranged
  `GET` answered `200` with the whole object), `:no_content_range` (a `206`
  without it), `:no_etag` (a `GET` without its `ETag`), `:bad_stamps` (a
  listed `LastModified` that is not a date) or `:no_part_etag` (an uploaded
  part without its `ETag`).
  """
  def misbehave(bucket, how), do: :ets.insert(@table, {{:misbehave, bucket, how}, true})

  defp misbehaving?(bucket, how), do: :ets.member(@table, {:misbehave, bucket, how})

  @doc "Lists at most `size` keys of `bucket` per page."
  def page_size(bucket, size), do: :ets.insert(@table, {{:page_size, bucket}, size})

  @doc "Calls `fun` with each request against `bucket`, as `{method, key}`, before answering it."
  def before_each(bucket, fun), do: :ets.insert(@table, {{:before, bucket}, fun})

  @impl true
  def request(method, url, body, headers, _http_opts) do
    uri = URI.parse(url)
    # Path-style, as ExAws builds a URL unless told `virtual_host: true`.
    [bucket | rest] = uri.path |> String.trim_leading("/") |> String.split("/")
    key = rest |> Enum.join("/") |> URI.decode()
    query = URI.decode_query(uri.query || "")
    headers = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

    :ets.insert(
      @table,
      {{:request, bucket, System.unique_integer([:monotonic])}, {method, key, query, headers}}
    )

    with [{_before, fun}] <- :ets.lookup(@table, {:before, bucket}), do: fun.({method, key})

    case :ets.lookup(@table, {:failing, bucket}) do
      [{_failing, {status, failing}}] when failing in [:any, method] ->
        respond(status, "<Error><Code>Stubbed</Code></Error>")

      _answering ->
        answer(method, bucket, key, query, headers, body)
    end
  end

  defp answer(:head, bucket, key, _query, _headers, _body) do
    case :ets.lookup(@table, {:object, bucket, key}) do
      [] ->
        respond(404, "")

      [{_key, {body, etag, _last_modified}}] ->
        respond(200, "", [{"ETag", etag}, {"Content-Length", "#{byte_size(body)}"}])
    end
  end

  defp answer(:get, bucket, "", query, _headers, _body), do: list(bucket, query)

  defp answer(:get, bucket, key, _query, headers, _body) do
    case :ets.lookup(@table, {:object, bucket, key}) do
      [] ->
        respond(404, "<Error><Code>NoSuchKey</Code></Error>")

      [{_key, {body, etag, _last_modified}}] ->
        cond do
          headers["if-match"] not in [nil, etag] ->
            respond(412, "<Error><Code>PreconditionFailed</Code></Error>")

          (range = headers["range"]) && not misbehaving?(bucket, :ignore_range) ->
            ranged(bucket, body, etag, range)

          true ->
            respond(200, body, etag_header(bucket, etag))
        end
    end
  end

  defp answer(:delete, bucket, key, %{"uploadId" => upload_id}, _headers, _body) do
    :ets.delete(@table, {:upload, bucket, key, upload_id})
    respond(204, "")
  end

  defp answer(:delete, bucket, key, _query, _headers, _body) do
    :ets.delete(@table, {:object, bucket, key})
    respond(204, "")
  end

  defp answer(:post, bucket, key, %{"uploads" => _}, _headers, _body) do
    upload_id = "upload-#{System.unique_integer([:positive])}"
    :ets.insert(@table, {{:upload, bucket, key, upload_id}, %{}})

    respond(200, """
    <InitiateMultipartUploadResult><Bucket>#{bucket}</Bucket><Key>#{escape(key)}</Key>\
    <UploadId>#{upload_id}</UploadId></InitiateMultipartUploadResult>
    """)
  end

  defp answer(:put, bucket, key, %{"partNumber" => number, "uploadId" => upload_id}, _h, body) do
    [{upload, parts}] = :ets.lookup(@table, {:upload, bucket, key, upload_id})
    :ets.insert(@table, {upload, Map.put(parts, String.to_integer(number), body)})
    etag = if misbehaving?(bucket, :no_part_etag), do: [], else: [{"ETag", ~s("part-#{number}")}]
    respond(200, "", etag)
  end

  defp answer(:post, bucket, key, %{"uploadId" => upload_id}, _headers, _body) do
    [{upload, parts}] = :ets.lookup(@table, {:upload, bucket, key, upload_id})
    :ets.delete(@table, upload)
    body = parts |> Enum.sort() |> Enum.map_join(&elem(&1, 1))
    put(bucket, key, body)

    respond(200, """
    <CompleteMultipartUploadResult><Bucket>#{bucket}</Bucket><Key>#{escape(key)}</Key>\
    <ETag>"done"</ETag></CompleteMultipartUploadResult>
    """)
  end

  defp answer(:put, bucket, key, _query, _headers, body) do
    put(bucket, key, body)
    respond(200, "", [{"ETag", ~s("put")}])
  end

  # As S3 does, any range of an empty object is not satisfiable.
  defp ranged(_bucket, "", _etag, _range),
    do: respond(416, "<Error><Code>InvalidRange</Code></Error>")

  defp ranged(bucket, body, etag, "bytes=" <> range) do
    [first, last] = range |> String.split("-") |> Enum.map(&String.to_integer/1)
    last = min(last, byte_size(body) - 1)
    short = if misbehaving?(bucket, :short_reads), do: 1, else: 0

    content_range =
      if misbehaving?(bucket, :no_content_range),
        do: [],
        else: [{"Content-Range", "bytes #{first}-#{last}/#{byte_size(body)}"}]

    respond(
      206,
      binary_part(body, first, last - first + 1 - short),
      content_range ++ etag_header(bucket, etag)
    )
  end

  defp etag_header(bucket, etag),
    do: if(misbehaving?(bucket, :no_etag), do: [], else: [{"ETag", etag}])

  # The token is the last key of the page before, so a page starts after it.
  defp list(bucket, %{"list-type" => "2"} = query) do
    prefix = query["prefix"] || ""
    after_key = query["continuation-token"]

    size =
      case :ets.lookup(@table, {:page_size, bucket}) do
        [{_size, size}] -> size
        [] -> 1000
      end

    matching =
      bucket
      |> keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.drop_while(&(after_key && &1 <= after_key))

    {page, rest} = Enum.split(matching, size)

    contents =
      Enum.map_join(page, fn key ->
        [{_key, {body, etag, last_modified}}] = :ets.lookup(@table, {:object, bucket, key})

        "<Contents><Key>#{escape(key)}</Key>" <>
          "<LastModified>#{stamp(bucket, last_modified)}</LastModified>" <>
          "<ETag>#{escape(etag)}</ETag><Size>#{byte_size(body)}</Size></Contents>"
      end)

    next =
      if rest == [],
        do: "",
        else: "<NextContinuationToken>#{escape(List.last(page))}</NextContinuationToken>"

    respond(200, """
    <ListBucketResult><Name>#{bucket}</Name><Prefix>#{escape(prefix)}</Prefix>\
    <KeyCount>#{length(page)}</KeyCount><IsTruncated>#{rest != []}</IsTruncated>\
    #{next}#{contents}</ListBucketResult>
    """)
  end

  defp stamp(bucket, last_modified) do
    if misbehaving?(bucket, :bad_stamps),
      do: "yesterday",
      else: DateTime.to_iso8601(last_modified)
  end

  defp respond(status, body, headers \\ []),
    do: {:ok, %{status_code: status, headers: headers, body: body}}

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
