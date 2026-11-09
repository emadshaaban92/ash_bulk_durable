defmodule AshBulkDurable.Storage.Local do
  @moduledoc """
  An `AshBulkDurable.Core.Storage` that keeps staged files on the server's
  own disk.

  It suits an application on one node, or on several that share a volume
  mounted at the same path. A worker can start on any node that runs
  `AshBulkDurable.Core.Poller`, so on several nodes without a shared volume
  a run that lands on another node than the one that staged its files finds
  them missing, and the rows that needed them fail with
  `AshBulkDurable.Core.StagedFileError`. Use an object store there.

  ## Setting it up

      config :ash_bulk_durable, storage: AshBulkDurable.Storage.Local

      config :ash_bulk_durable, AshBulkDurable.Storage.Local,
        root: "/var/lib/my_app/bulk_files"

  Options, read when they are used, so `config/runtime.exs` can set them:

    * `:root` — the directory files are written under. Required. A key's
      `/`-separated segments become directories below it.

  Every callback and function here also takes them in its `opts`, over the
  configured ones.

  ## Staging a file

  The engine only fetches, deletes and lists. Putting a file there is the
  host's: `put_file/3` stores a file the server holds (a companion the
  browser uploaded, say) under its key.

  ## Keys

  A key is `/`-separated, relative and valid UTF-8. One that could reach
  outside `:root` (absolute, empty, an empty, `.` or `..` segment, a
  backslash or a NUL) is refused with `{:error, :unsafe_key}` on every read
  and write. `list_files/2` reads its prefix as a directory, with or
  without a trailing `/`.

  ## What is left on disk

  Deleting a file also removes the directories it leaves empty, up to
  `:root`, so the sweep's listing does not grow with every bulk action ever
  staged. A node that dies
  while `put_file/3` copies leaves a `<key>.<n>.partial` file beside the
  key; under the staging prefix the daily sweep deletes it once it is a day
  old, since no bulk action holds that key. Nothing deletes files outside
  it.

  ## Adding to it

  A host that wants more of its store than the engine needs (presigned
  links for a browser, say) writes a module of its own and points
  `:storage` at that:

      defmodule MyApp.BulkActions.Storage do
        use AshBulkDurable.Storage.Local

        def presigned_put_url(key, opts), do: ...
      end

  `use` delegates `fetch_file/3`, `delete_file/2`, `list_files/2`,
  `check_config/1` and `put_file/3` here, each of them overridable. Options
  given to `use` (`use AshBulkDurable.Storage.Local, root: ...`) go to each
  of them, under the ones a call passes, so a host module can keep its own
  root. They are read when the host module compiles, so a `:root` that
  `config/runtime.exs` sets belongs in config, not in `use`. The injected
  `put_file/3` takes its `opts` without a default; override it the same
  way.
  """
  @behaviour AshBulkDurable.Core.Storage

  @doc false
  defmacro __using__(use_opts) do
    quote do
      @behaviour AshBulkDurable.Core.Storage

      @ash_bulk_durable_local_opts unquote(use_opts)

      @impl AshBulkDurable.Core.Storage
      def fetch_file(key, path, opts),
        do:
          AshBulkDurable.Storage.Local.fetch_file(
            key,
            path,
            __ash_bulk_durable_local_opts__(opts)
          )

      @impl AshBulkDurable.Core.Storage
      def delete_file(key, opts),
        do: AshBulkDurable.Storage.Local.delete_file(key, __ash_bulk_durable_local_opts__(opts))

      @impl AshBulkDurable.Core.Storage
      def list_files(prefix, opts),
        do: AshBulkDurable.Storage.Local.list_files(prefix, __ash_bulk_durable_local_opts__(opts))

      @impl AshBulkDurable.Core.Storage
      def check_config(opts),
        do: AshBulkDurable.Storage.Local.check_config(__ash_bulk_durable_local_opts__(opts))

      @doc "Stages `source` under `key`; see `AshBulkDurable.Storage.Local.put_file/3`."
      def put_file(key, source, opts),
        do:
          AshBulkDurable.Storage.Local.put_file(
            key,
            source,
            __ash_bulk_durable_local_opts__(opts)
          )

      defp __ash_bulk_durable_local_opts__(opts),
        do: Keyword.merge(@ash_bulk_durable_local_opts, opts)

      defoverridable fetch_file: 3, delete_file: 2, list_files: 2, check_config: 1, put_file: 3
    end
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def fetch_file(key, path, opts \\ []) do
    with {:ok, source} <- path(key, opts), do: File.cp(source, path)
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def delete_file(key, opts \\ []) do
    with {:ok, target} <- path(key, opts) do
      case File.rm(target) do
        :ok -> prune_empty_dirs(key, opts)
        {:error, :enoent} -> :ok
        other -> other
      end
    end
  end

  # Removes the key's directories that the delete left empty, deepest
  # first, stopping at the first one that still holds something. `:root`
  # itself stays. A `put_file/3` racing it retries the directory it lost.
  # sobelow_skip ["Traversal.FileModule"]
  defp prune_empty_dirs(key, opts) do
    root = root(opts)

    key
    |> Path.split()
    |> Enum.drop(-1)
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case File.rmdir(Path.join(root, dir)) do
        :ok -> {:cont, :ok}
        {:error, _not_empty_or_gone} -> {:halt, :ok}
      end
    end)
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def list_files(prefix, opts \\ []) do
    prefix = String.trim_trailing(prefix, "/")

    with {:ok, dir} <- path(prefix, opts) do
      # The pattern is matched relative to `dir`, so a `:root` holding glob
      # characters (`{`, `[`, `*`) is read as the path it is. A file deleted
      # between the listing and its stat is left out.
      files =
        for relative <- :filelib.wildcard(~c"**", String.to_charlist(dir)),
            relative = List.to_string(relative),
            {:ok, %File.Stat{type: :regular, mtime: mtime}} <-
              [File.stat(Path.join(dir, relative), time: :posix)] do
          %{key: Path.join(prefix, relative), last_modified: DateTime.from_unix!(mtime)}
        end

      {:ok, files}
    end
  end

  @doc """
  Stores the local file at `source` under `key`. The file is copied beside
  its destination and renamed in, so a reader never sees half of it.
  """
  @spec put_file(String.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  # sobelow_skip ["Traversal.FileModule"]
  def put_file(key, source, opts \\ []) do
    with {:ok, target} <- path(key, opts) do
      partial = "#{target}.#{System.unique_integer([:positive])}.partial"

      with :ok <- copy_beside(source, partial, _retries = 5),
           :ok <- File.rename(partial, target) do
        :ok
      else
        error ->
          File.rm(partial)
          error
      end
    end
  end

  # The copy runs first and makes the directory only when it is missing,
  # so a directory that a sibling's `delete_file/2` pruned after a `mkdir_p`
  # is the same case as one never made: the copy answers `:enoent`, and the
  # directory is made and the copy tried again. A prune can also land inside
  # `File.mkdir_p/1` (between a parent's `:eexist` and its `dir?` check, or
  # before a child's mkdir), failing it with `:enotdir` or `:enoent`, so its
  # answer is ignored and the next copy decides; up to five tries cover
  # several prunes along the same chain. A real failure (a file where a
  # directory goes, a read-only disk) still comes back from the last copy.
  # Once the partial file is in it, the directory is not empty and no prune
  # takes it.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy_beside(source, partial, retries) do
    case File.cp(source, partial) do
      {:error, :enoent} = error when retries > 0 ->
        if File.exists?(source), do: make_dir_and_copy(source, partial, retries), else: error

      other ->
        other
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp make_dir_and_copy(source, partial, retries) do
    _ = File.mkdir_p(Path.dirname(partial))
    copy_beside(source, partial, retries - 1)
  end

  @impl true
  @doc """
  `:ok` when a `:root` is configured (or given in `opts`), so a node with
  none fails when its poller starts rather than at its first sweep.
  """
  def check_config(opts \\ []) do
    _root = root(opts)
    :ok
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  @doc """
  Where `key` sits on disk, or `{:error, :unsafe_key}` for a key that could
  reach outside `:root`.
  """
  @spec path(String.t(), keyword()) :: {:ok, Path.t()} | {:error, :unsafe_key}
  def path(key, opts \\ []) do
    if safe_key?(key) do
      {:ok, Path.join(root(opts), key)}
    else
      {:error, :unsafe_key}
    end
  end

  defp safe_key?(key) when is_binary(key) and key != "" do
    String.valid?(key) and not String.contains?(key, ["\\", <<0>>]) and
      key |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  defp safe_key?(_key), do: false

  defp root(opts) do
    Keyword.get_lazy(opts, :root, fn ->
      :ash_bulk_durable
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:root)
    end)
    |> case do
      root when is_binary(root) and root != "" ->
        root

      _missing ->
        raise ArgumentError, """
        AshBulkDurable.Storage.Local needs a `:root` directory:

            config :ash_bulk_durable, AshBulkDurable.Storage.Local, root: "/var/lib/my_app/bulk_files"
        """
    end
  end
end
