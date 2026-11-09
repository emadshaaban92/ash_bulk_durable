defmodule AshBulkDurable.Storage.LocalTest do
  use ExUnit.Case, async: true

  alias AshBulkDurable.Storage.Local

  @moduletag :tmp_dir

  defmodule Extended do
    @moduledoc false
    use AshBulkDurable.Storage.Local

    @impl AshBulkDurable.Core.Storage
    def delete_file(_key, _opts), do: {:error, :kept}
  end

  defmodule OwnRoot do
    @moduledoc false
    use AshBulkDurable.Storage.Local,
      root: Path.join(System.tmp_dir!(), "ash_bulk_durable_own_root_test")
  end

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    source = Path.join(tmp_dir, "source")
    File.write!(source, "the bytes")
    %{opts: [root: root], root: root, source: source, tmp_dir: tmp_dir}
  end

  test "a file put under a key is fetched back to a path", %{opts: opts, source: source} = ctx do
    assert :ok = Local.put_file("bulk-staging/u/1/logo.zip", source, opts)

    dest = Path.join(ctx.tmp_dir, "dest")
    File.write!(dest, "")
    assert :ok = Local.fetch_file("bulk-staging/u/1/logo.zip", dest, opts)
    assert File.read!(dest) == "the bytes"
  end

  test "putting a key again replaces the file, leaving nothing beside it",
       %{opts: opts, root: root, source: source} = ctx do
    other = Path.join(ctx.tmp_dir, "other")
    File.write!(other, "newer")

    :ok = Local.put_file("bulk-staging/u/a.csv", source, opts)
    :ok = Local.put_file("bulk-staging/u/a.csv", other, opts)

    assert File.read!(Path.join(root, "bulk-staging/u/a.csv")) == "newer"
    assert File.ls!(Path.join(root, "bulk-staging/u")) == ["a.csv"]
  end

  test "a missing key fails the fetch", %{opts: opts} = ctx do
    assert {:error, :enoent} =
             Local.fetch_file("bulk-staging/none", Path.join(ctx.tmp_dir, "dest"), opts)
  end

  test "a deleted key is gone, and deleting it again is :ok",
       %{opts: opts, root: root, source: source} do
    :ok = Local.put_file("bulk-staging/u/a.csv", source, opts)

    assert :ok = Local.delete_file("bulk-staging/u/a.csv", opts)
    refute File.exists?(Path.join(root, "bulk-staging/u/a.csv"))
    assert :ok = Local.delete_file("bulk-staging/u/a.csv", opts)
  end

  test "listing a prefix gives every file under it with its key and mtime",
       %{opts: opts, root: root, source: source} do
    :ok = Local.put_file("bulk-staging/u/1/a.zip", source, opts)
    :ok = Local.put_file("bulk-staging/u/2/.hidden", source, opts)
    :ok = Local.put_file("elsewhere/b.zip", source, opts)

    old = ~U[2026-01-01 00:00:00Z]
    File.touch!(Path.join(root, "bulk-staging/u/1/a.zip"), DateTime.to_unix(old))

    assert {:ok, files} = Local.list_files("bulk-staging/", opts)

    assert Enum.sort_by(files, & &1.key) == [
             %{key: "bulk-staging/u/1/a.zip", last_modified: old},
             %{
               key: "bulk-staging/u/2/.hidden",
               last_modified: Enum.find(files, &(&1.key =~ "hidden")).last_modified
             }
           ]
  end

  test "listing a prefix nothing was put under is empty", %{opts: opts} do
    assert {:ok, []} = Local.list_files("bulk-staging/", opts)
  end

  test "a key that could reach outside the root is refused everywhere",
       %{opts: opts, root: root, source: source} = ctx do
    dest = Path.join(ctx.tmp_dir, "dest")

    for key <- ["", "/etc/passwd", "a/../../x", "./a", "a//b", "a\\b", "a\0b", "..", <<0xFF>>] do
      assert {:error, :unsafe_key} = Local.put_file(key, source, opts), inspect(key)
      assert {:error, :unsafe_key} = Local.fetch_file(key, dest, opts), inspect(key)
      assert {:error, :unsafe_key} = Local.delete_file(key, opts), inspect(key)
      assert {:error, :unsafe_key} = Local.list_files(key, opts), inspect(key)
    end

    refute File.exists?(root)
  end

  test "a file key with a trailing slash is refused; a listed prefix may have one",
       %{opts: opts, source: source} do
    assert {:error, :unsafe_key} = Local.put_file("bulk-staging/a/", source, opts)

    :ok = Local.put_file("bulk-staging/a", source, opts)
    assert {:ok, [%{key: "bulk-staging/a"}]} = Local.list_files("bulk-staging", opts)
    assert {:ok, [%{key: "bulk-staging/a"}]} = Local.list_files("bulk-staging/", opts)
  end

  test "a root holding glob characters is listed as the path it is",
       %{source: source, tmp_dir: tmp_dir} do
    for name <- ["root{1}", "root[1]", "root*"] do
      opts = [root: Path.join(tmp_dir, name)]
      :ok = Local.put_file("bulk-staging/u/a.zip", source, opts)

      assert {:ok, [%{key: "bulk-staging/u/a.zip"}]} = Local.list_files("bulk-staging/", opts),
             name
    end
  end

  test "a write that fails to land leaves no partial file beside its key",
       %{opts: opts, root: root, source: source} do
    File.mkdir_p!(Path.join(root, "bulk-staging/taken/inside"))

    assert {:error, _reason} = Local.put_file("bulk-staging/taken", source, opts)
    assert File.ls!(Path.join(root, "bulk-staging")) == ["taken"]
  end

  test "an empty root is refused", %{source: source} do
    assert_raise ArgumentError, ~r/needs a `:root`/, fn ->
      Local.put_file("bulk-staging/a", source, root: "")
    end
  end

  test "a module that uses it gets the callbacks, and can override them",
       %{opts: opts, source: source} = ctx do
    :ok = Local.put_file("bulk-staging/a", source, opts)
    dest = Path.join(ctx.tmp_dir, "dest")

    assert :ok = Extended.fetch_file("bulk-staging/a", dest, opts)
    assert {:ok, [%{key: "bulk-staging/a"}]} = Extended.list_files("bulk-staging/", opts)
    assert {:error, :kept} = Extended.delete_file("bulk-staging/a", opts)
  end

  test "options given to use reach every delegated call, under the call's own",
       %{source: source, tmp_dir: tmp_dir} do
    own = Path.join(System.tmp_dir!(), "ash_bulk_durable_own_root_test")
    on_exit(fn -> File.rm_rf!(own) end)

    assert :ok = OwnRoot.check_config([])
    assert :ok = OwnRoot.put_file("bulk-staging/a", source, [])
    assert File.exists?(Path.join(own, "bulk-staging/a"))
    assert {:ok, [%{key: "bulk-staging/a"}]} = OwnRoot.list_files("bulk-staging/", [])

    dest = Path.join(tmp_dir, "dest")
    assert :ok = OwnRoot.fetch_file("bulk-staging/a", dest, [])
    assert :ok = OwnRoot.delete_file("bulk-staging/a", [])
    refute File.exists?(Path.join(own, "bulk-staging/a"))

    other = Path.join(tmp_dir, "other")
    assert :ok = OwnRoot.put_file("bulk-staging/b", source, root: other)
    assert File.exists?(Path.join(other, "bulk-staging/b"))
  end

  test "deleting a file removes the directories it leaves empty, up to the root",
       %{opts: opts, root: root, source: source} do
    :ok = Local.put_file("bulk-staging/u/1/companions/a.zip", source, opts)
    :ok = Local.put_file("bulk-staging/u/2/b.zip", source, opts)

    :ok = Local.delete_file("bulk-staging/u/1/companions/a.zip", opts)
    assert File.ls!(Path.join(root, "bulk-staging/u")) == ["2"]

    :ok = Local.delete_file("bulk-staging/u/2/b.zip", opts)
    assert File.ls!(root) == []
  end

  test "a put into a directory a delete just pruned makes it again",
       %{opts: opts, root: root, source: source} do
    :ok = Local.put_file("bulk-staging/u/1/old", source, opts)
    :ok = Local.delete_file("bulk-staging/u/1/old", opts)
    refute File.exists?(Path.join(root, "bulk-staging"))

    assert :ok = Local.put_file("bulk-staging/u/1/new", source, opts)
    assert File.read!(Path.join(root, "bulk-staging/u/1/new")) == "the bytes"
  end

  test "a missing source fails the put and leaves no directory behind",
       %{opts: opts, root: root} = ctx do
    assert {:error, :enoent} =
             Local.put_file("bulk-staging/a", Path.join(ctx.tmp_dir, "none"), opts)

    refute File.exists?(root)
  end

  test "check_config/1 says whether a root is set" do
    assert :ok = Local.check_config(root: "/var/lib/x")
    assert {:error, message} = Local.check_config(root: "")
    assert message =~ "needs a `:root`"
  end
end

defmodule AshBulkDurable.Storage.LocalConfigTest do
  # Sets the store's application config, so it runs alone.
  use ExUnit.Case, async: false

  alias AshBulkDurable.Storage.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source")
    File.write!(source, "the bytes")
    %{root: Path.join(tmp_dir, "root"), source: source}
  end

  test "the root comes from config when opts leave it out", %{root: root, source: source} do
    previous = Application.get_env(:ash_bulk_durable, Local)
    Application.put_env(:ash_bulk_durable, Local, root: root)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_bulk_durable, Local, previous),
        else: Application.delete_env(:ash_bulk_durable, Local)
    end)

    assert :ok = Local.put_file("bulk-staging/a", source)
    assert File.exists?(Path.join(root, "bulk-staging/a"))
  end

  test "check_config/1 reads the configured root" do
    previous = Application.get_env(:ash_bulk_durable, Local)
    Application.delete_env(:ash_bulk_durable, Local)
    on_exit(fn -> if previous, do: Application.put_env(:ash_bulk_durable, Local, previous) end)

    assert {:error, _message} = Local.check_config()
    Application.put_env(:ash_bulk_durable, Local, root: "/var/lib/x")
    assert :ok = Local.check_config()
  end
end
