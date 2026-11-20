defmodule AshBulkDurable.Core.StagedFiles do
  @moduledoc """
  Whose staged files a bulk action may name. Every key in `:staged_files`
  must start with its owner's staging prefix, `bulk-staging/<owner>/`, where
  `<owner>` is `AshBulkDurable.Core.Owner.worker_key/1` of the submitting
  scope, and be a plain key, one every shipped store accepts as it is:
  valid UTF-8, with no empty, `.` or `..` segment (so no `//` and no
  trailing `/`), no backslash and no NUL. `AshBulkDurable.Core.create/4`,
  `AshBulkDurable.Core.Retry.retry/2` and `retry_row/2` refuse any other key
  before writing anything, whoever calls them.

  The worker fetches every staged file of a bulk action and deletes them
  once it no longer needs them, so a key naming another user's file, or one
  such as `bulk-staging/<owner>/../<other>/x` that starts with the prefix yet
  escapes it, would let one user read or delete what another staged. The
  key is usually computed by the server that presigned its upload; this
  makes the rule hold for a caller that takes it from a request too. A key
  such as `bulk-staging/<owner>//x` or `bulk-staging/<owner>/./x` stays
  under the owner's prefix, but the worker could not fetch it from the
  local store, so it is refused at submit rather than failing the bulk
  action later.

  An owner whose worker key is not one plain path segment (it holds a `/`,
  or is `""`, `.` or `..`) is refused any staged file: its prefix would
  also cover, or resolve into, another owner's files.
  """

  @root "bulk-staging/"

  @doc "The staging prefix of `owner`, a worker key: `bulk-staging/<owner>/`."
  def prefix(owner), do: "#{@root}#{owner}/"

  @doc "Whether `key` is a staging key `owner` may name."
  def owned?(key, owner) when is_binary(key) do
    segment?(owner) and String.starts_with?(key, prefix(owner)) and plain?(key)
  end

  def owned?(_key, _owner), do: false

  @doc """
  `:ok` when every key of `staged_files`, `%{name => storage_key}` or a list
  of `{name, storage_key}` pairs, is `owner`'s, or `{:error, error}` naming
  the first that is not. Anything else is refused too.
  """
  def check(staged_files, owner) when is_map(staged_files) or is_list(staged_files) do
    case Enum.find(staged_files, &(not owned_pair?(&1, owner))) do
      nil -> :ok
      {name, key} -> refuse(refusal(name, key, owner))
      other -> refuse("#{inspect(other)} is not a {name, storage_key} pair")
    end
  end

  def check(staged_files, _owner),
    do: refuse("must be a map of name => storage key, got: #{inspect(staged_files)}")

  defp owned_pair?({_name, key}, owner), do: owned?(key, owner)
  defp owned_pair?(_other, _owner), do: false

  defp refuse(message) do
    {:error,
     Ash.Error.to_error_class(
       Ash.Error.Changes.InvalidArgument.exception(field: :staged_files, message: message)
     )}
  end

  defp refusal(name, key, owner) do
    if segment?(owner),
      do:
        "the key #{inspect(key)} of #{inspect(name)} must start with " <>
          "\"#{prefix(owner)}\" and #{plain_rule()}",
      else:
        "the owner's worker key #{inspect(owner)} is not one plain path segment, " <>
          "so it owns no staged file: #{inspect(name)} is refused"
  end

  # The rule `plain?/1` checks, as the refusals word it.
  @doc false
  def plain_rule,
    do: ~s(have no empty, "." or ".." segment, backslash or NUL)

  # A `/`-separated relative key every shipped store takes as it is: the
  # local store refuses any other on every read and write.
  defp plain?(key) do
    String.valid?(key) and not String.contains?(key, ["\\", <<0>>]) and
      key |> String.split("/") |> Enum.all?(&(&1 not in ["", ".", ".."]))
  end

  # One segment of a path that names a directory of its own.
  defp segment?(owner) do
    owner = to_string(owner)
    owner not in ["", ".", ".."] and not String.contains?(owner, "/")
  end
end
