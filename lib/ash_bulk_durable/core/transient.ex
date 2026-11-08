defmodule AshBulkDurable.Core.Transient do
  @moduledoc """
  Tells a database's trouble from a row's. A row whose write fails because
  the database could not serve it (the connection dropped, a deadlock, a lock
  or statement timeout, the server shutting down or out of resources) has
  nothing wrong with it, and would only make its owner retry it by hand once
  the database is back. The worker raises such an error instead of failing
  the row with it, so the run stops with the row still `:resolved` and is
  started again once its liveness hint goes stale.

  An error is transient when it is, or wraps, a `DBConnection.ConnectionError`,
  an `Ash.Error.Invalid.Unavailable`, or a `Postgrex.Error` whose SQLSTATE is
  one of:

    * class 08, connection exception;
    * class 40, transaction rollback (a serialization failure, a deadlock);
    * `55P03`, lock not available (`lock_timeout`, `NOWAIT`). AshPostgres
      turns it into `Ash.Error.Invalid.Unavailable` on its own writes, which
      Ash documents as a resource unavailable for now, through locking at
      the data layer or a host's own reason: either way, worth trying again;
    * class 53, insufficient resources (disk full, out of memory, too many
      connections);
    * class 57, operator intervention (`statement_timeout`, a server
      shutting down);
    * class 58, system error (an I/O error).

  Anything else stays the row's: a validation, a policy, a constraint
  violation, and a raise from the host's own code, however it is worded.

  Ash keeps a raised exception it did not define only as its message
  (`Ash.Error.Unknown.UnknownError`'s `:error`, `Exception.format/2`'s
  `** (Module) message`), so a wrapped error is told by that message's
  first line.
  """

  @classes ~w(08 40 53 57 58)
  @codes ~w(55P03)

  @doc "Whether `error`, or any error it wraps, is the database's trouble."
  def transient?(%DBConnection.ConnectionError{}), do: true
  def transient?(%Ash.Error.Invalid.Unavailable{}), do: true
  def transient?(%Postgrex.Error{postgres: %{pg_code: code}}), do: transient_code?(code)
  def transient?(%Ash.Error.Unknown.UnknownError{error: message}), do: message?(message)
  def transient?(%Ash.Changeset{errors: errors}), do: transient?(errors)
  def transient?(%{errors: errors}) when is_list(errors), do: transient?(errors)
  def transient?(errors) when is_list(errors), do: Enum.any?(errors, &transient?/1)
  def transient?(_error), do: false

  defp message?("** (DBConnection.ConnectionError) " <> _rest), do: true

  # The severity comes first, in the server's `lc_messages` language.
  defp message?("** (Postgrex.Error) " <> rest) do
    case Regex.run(~r/\A\S+ ([0-9A-Z]{5}) \(/u, rest) do
      [_, code] -> transient_code?(code)
      nil -> false
    end
  end

  defp message?(_message), do: false

  defp transient_code?(<<class::binary-size(2), _::binary-size(3)>> = code),
    do: class in @classes or code in @codes

  defp transient_code?(_code), do: false
end
