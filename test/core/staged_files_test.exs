defmodule AshBulkDurable.Core.StagedFilesTest do
  @moduledoc """
  A bulk action names only its owner's staged files
  (`AshBulkDurable.Core.StagedFiles`), whoever calls the core: a key outside
  `bulk-staging/<owner>/`, or escaping it, is refused before anything is
  written.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  alias AshBulkDurable.Core.StagedFiles
  alias AshBulkDurable.Test.{BulkAction, Region, Scope}

  describe "owned?/2" do
    test "a key under the owner's prefix is theirs" do
      assert StagedFiles.owned?("bulk-staging/u1/abc/companions/logo.zip", "u1")
      assert StagedFiles.owned?("bulk-staging/42/abc/logo.zip", 42)
    end

    test "another owner's key, or one outside the staging prefix, is not" do
      refute StagedFiles.owned?("bulk-staging/u2/abc/logo.zip", "u1")
      refute StagedFiles.owned?("bulk-staging/u10/abc/logo.zip", "u1")
      refute StagedFiles.owned?("bulk-staging/u1", "u1")
      refute StagedFiles.owned?("public/u1/logo.zip", "u1")
      refute StagedFiles.owned?("other/bulk-staging/u1/logo.zip", "u1")
    end

    test "a key that starts with the prefix yet escapes it is not" do
      refute StagedFiles.owned?("bulk-staging/u1/../u2/logo.zip", "u1")
      refute StagedFiles.owned?("bulk-staging/u1/abc/../../../public/x", "u1")
    end

    test "a key that is not a string is not" do
      refute StagedFiles.owned?(nil, "u1")
      refute StagedFiles.owned?(:"bulk-staging/u1/logo.zip", "u1")
    end

    # Owner "a"'s prefix would cover owner "a/b"'s files, and a store that
    # normalises paths would read "bulk-staging/./u2/x" as owner "u2"'s.
    test "an owner whose key is not one plain path segment owns nothing" do
      refute StagedFiles.owned?("bulk-staging/a/b/logo.zip", "a/b")
      refute StagedFiles.owned?("bulk-staging//u2/logo.zip", "")
      refute StagedFiles.owned?("bulk-staging/./u2/logo.zip", ".")
      refute StagedFiles.owned?("bulk-staging/../u2/logo.zip", "..")
    end
  end

  describe "check/2" do
    test "is :ok for no staged files, or only the owner's" do
      assert :ok = StagedFiles.check(%{}, "u1")
      assert :ok = StagedFiles.check(%{"logo" => "bulk-staging/u1/a/logo.zip"}, "u1")
      assert :ok = StagedFiles.check([logo: "bulk-staging/u1/a/logo.zip"], "u1")
    end

    test "refuses naming the first key that is not the owner's" do
      assert {:error, %Ash.Error.Invalid{errors: [error]}} =
               StagedFiles.check(
                 %{
                   "logo" => "bulk-staging/u1/a/logo.zip",
                   "photos" => "bulk-staging/u2/a/photos.zip"
                 },
                 "u1"
               )

      assert %Ash.Error.Changes.InvalidArgument{field: :staged_files, message: message} = error
      assert message =~ ~s("photos")
      assert message =~ ~s("bulk-staging/u1/")
    end

    test "says why an owner whose key is not one plain path segment is refused" do
      assert {:error, %Ash.Error.Invalid{errors: [%{message: message}]}} =
               StagedFiles.check(%{"logo" => "bulk-staging/a/b/logo.zip"}, "a/b")

      assert message =~ "not one plain path segment"
    end

    test "refuses what is not a map or a list of pairs, rather than raising" do
      for staged_files <- [nil, "bulk-staging/u1/logo.zip", 42, ["bulk-staging/u1/logo.zip"]] do
        assert {:error, %Ash.Error.Invalid{errors: [%{field: :staged_files}]}} =
                 StagedFiles.check(staged_files, "u1")
      end
    end
  end

  describe "Core.create/4" do
    setup %{super_user: user} do
      %{
        user: user,
        scope: Scope.new(actor: user),
        code: "SF#{System.unique_integer([:positive])}"
      }
    end

    defp rows(code), do: [%{input: %{code: code, name: "Region #{code}", native_name: "ا"}}]

    defp submitted(user) do
      BulkAction
      |> Ash.Query.filter(user_id == ^user.id)
      |> Ash.read!(authorize?: false)
    end

    test "keeps the owner's own staged files", ctx do
      key = "bulk-staging/#{ctx.user.id}/abc/companions/logo.zip"

      assert {:ok, %{staged_files: %{"logo" => ^key}}} =
               AshBulkDurable.Core.create(Region, :create, rows(ctx.code),
                 scope: ctx.scope,
                 staged_files: %{"logo" => key}
               )
    end

    test "takes staged_files: nil as none, as a retry does", ctx do
      assert {:ok, %{staged_files: staged_files}} =
               AshBulkDurable.Core.create(Region, :create, rows(ctx.code),
                 scope: ctx.scope,
                 staged_files: nil
               )

      assert staged_files == %{}
    end

    test "keeps a list of {name, key} pairs as a map, as a retry does", ctx do
      key = "bulk-staging/#{ctx.user.id}/abc/companions/logo.zip"

      assert {:ok, %{staged_files: %{"logo" => ^key}}} =
               AshBulkDurable.Core.create(Region, :create, rows(ctx.code),
                 scope: ctx.scope,
                 staged_files: [{"logo", key}]
               )
    end

    test "refuses staged_files that are not a map, writing nothing", ctx do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: :staged_files}]}} =
               AshBulkDurable.Core.create(Region, :create, rows(ctx.code),
                 scope: ctx.scope,
                 staged_files: "bulk-staging/#{ctx.user.id}/logo.zip"
               )

      assert submitted(ctx.user) == []
    end

    test "refuses another owner's staged file, writing nothing", ctx do
      other = Ecto.UUID.generate()

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :staged_files}]}} =
               AshBulkDurable.Core.create(Region, :create, rows(ctx.code),
                 scope: ctx.scope,
                 staged_files: %{"logo" => "bulk-staging/#{other}/abc/companions/logo.zip"}
               )

      assert submitted(ctx.user) == []
    end

    test "refuses a key that escapes the owner's prefix, writing nothing", ctx do
      key = "bulk-staging/#{ctx.user.id}/../#{Ecto.UUID.generate()}/logo.zip"

      assert {:error, %Ash.Error.Invalid{errors: [%{field: :staged_files}]}} =
               AshBulkDurable.Core.create(Region, :create, rows(ctx.code),
                 scope: ctx.scope,
                 staged_files: %{"logo" => key}
               )

      assert submitted(ctx.user) == []
    end

    test "a facade verb is refused the same way", ctx do
      assert {:error, %Ash.Error.Invalid{errors: [%{field: :staged_files}]}} =
               AshBulkDurable.bulk_create(rows(ctx.code) |> Enum.map(& &1.input), Region, :create,
                 scope: ctx.scope,
                 staged_files: %{"logo" => "bulk-staging/someone-else/logo.zip"}
               )

      assert submitted(ctx.user) == []
    end
  end
end
