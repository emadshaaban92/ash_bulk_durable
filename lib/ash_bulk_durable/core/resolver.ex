defmodule AshBulkDurable.Core.Resolver do
  @moduledoc """
  Resolves a `{:resolve, module, args}` reference in a row's input into the
  value the action receives, before the row's transaction opens.

  The worker resolves a chunk's references together: `c:prepare/2` once per
  resolver with every reference to it in the chunk, `c:resolve/3` per
  reference, `c:finish/1` once the chunk is resolved, whatever happened. What
  `c:resolve/3` returns is kept on the row (`resolved_data`), so it must
  survive a JSON round trip; a bulk action that crashes between resolving and
  writing does not resolve it again.

  A resolved value that needs the record it was written to (a staged file
  the record now references) implements `c:after_write/3`, which runs inside
  the row's transaction: an error fails the row. That is the chunk's
  transaction, which holds the bulk action lock
  (`AshBulkDurable.Core.BulkActionLock`), so `c:after_write/3` must do no
  storage or network I/O: do that in `c:resolve/3`, before the transaction
  opens, and only write to the database here, through the bulk action's repo.

  A resolved value kept on a row can stop being usable while the row waits for
  a correction: a staged file's object swept because no record references it
  yet. A resolver whose values can implements `c:lost/2`; the worker asks
  before each run, and resolves a lost value again.
  """

  alias AshBulkDurable.Core.Resolver.Context

  @doc "Readies a chunk's references to this resolver: `args` of each, in no order."
  @callback prepare(args :: [term()], Context.t()) :: {:ok, state :: term()} | {:error, term()}

  @doc "The value one reference resolves to."
  @callback resolve(args :: term(), state :: term(), Context.t()) ::
              {:ok, term()} | {:error, term()}

  @doc "Releases what `c:prepare/2` opened."
  @callback finish(state :: term()) :: :ok

  @doc """
  Runs in the row's transaction once `record` is written with `resolved`.
  That transaction holds the bulk action lock: no storage or network I/O here.
  """
  @callback after_write(record :: Ash.Resource.record(), resolved :: term(), Context.t()) ::
              :ok | {:error, term()}

  @doc """
  Those of `resolved`, values this resolver returned earlier, that can no
  longer be used. Runs before the staged files are downloaded, so the
  context's `staged_files` is empty. When it can't tell, a value is not lost:
  the write then says so, on the row.
  """
  @callback lost(resolved :: [term()], Context.t()) :: [term()]

  @optional_callbacks after_write: 3, lost: 2

  defmodule Context do
    @moduledoc """
    What a resolver may know of the bulk action: who runs it, in which
    tenant, and the files staged for it, downloaded to local paths and keyed
    as they were staged.
    """

    defstruct [:scope, :tenant, staged_files: %{}]

    @type t :: %__MODULE__{
            scope: term(),
            tenant: term(),
            staged_files: %{optional(term()) => Path.t()}
          }
  end
end
