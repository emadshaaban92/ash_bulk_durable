defmodule AshBulkDurable.Core.TransientTest do
  @moduledoc """
  `AshBulkDurable.Core.Transient.transient?/1` tells the database's own
  trouble from a row's, raw or as Ash wraps it.
  """
  use ExUnit.Case, async: true

  alias AshBulkDurable.Core.Transient

  defp postgrex(pg_code, code),
    do: %Postgrex.Error{
      postgres: %{severity: "ERROR", pg_code: pg_code, code: code, message: "the message"}
    }

  # As a row's error reaches the worker: wrapped by Ash, which keeps only
  # the message of an exception it did not define.
  defp wrapped(exception), do: Ash.Error.to_error_class(Ash.Error.to_ash_error(exception))

  test "a dropped connection, a deadlock, a lock or statement timeout, a shutdown are transient" do
    for {pg_code, code} <- [
          {"08006", :connection_failure},
          {"40001", :serialization_failure},
          {"40P01", :deadlock_detected},
          {"55P03", :lock_not_available},
          {"53300", :too_many_connections},
          {"57014", :query_canceled},
          {"57P01", :admin_shutdown},
          {"58030", :io_error}
        ] do
      error = postgrex(pg_code, code)
      assert Transient.transient?(error), pg_code
      assert Transient.transient?(wrapped(error)), pg_code
    end

    unavailable =
      Ash.Error.Invalid.Unavailable.exception(
        resource: __MODULE__,
        reason: "canceling statement due to lock timeout"
      )

    assert Transient.transient?(unavailable)
    assert Transient.transient?(Ash.Error.to_error_class(unavailable))

    error = %DBConnection.ConnectionError{message: "tcp recv: closed"}
    assert Transient.transient?(error)
    assert Transient.transient?(wrapped(error))
  end

  test "a constraint violation, an aborted transaction, a bad query are the row's" do
    for {pg_code, code} <- [
          {"23505", :unique_violation},
          {"23503", :foreign_key_violation},
          {"25P02", :in_failed_sql_transaction},
          {"42P01", :undefined_table},
          {"22003", :numeric_value_out_of_range}
        ] do
      error = postgrex(pg_code, code)
      refute Transient.transient?(error), pg_code
      refute Transient.transient?(wrapped(error)), pg_code
    end
  end

  test "the severity word may be in any language" do
    error = %Postgrex.Error{
      postgres: %{severity: "ОШИБКА", pg_code: "40P01", code: :deadlock_detected, message: "x"}
    }

    assert Transient.transient?(wrapped(error))

    refute Transient.transient?(
             wrapped(%{error | postgres: %{error.postgres | pg_code: "23505"}})
           )
  end

  test "a host's raise is the row's, however it is worded" do
    refute Transient.transient?(
             wrapped(RuntimeError.exception("ERROR 40P01 (deadlock_detected)"))
           )

    refute Transient.transient?(
             wrapped(
               RuntimeError.exception("** (Postgrex.Error) ERROR 40P01 (deadlock_detected)")
             )
           )
  end

  test "an Ash validation error is the row's" do
    refute Transient.transient?(
             Ash.Error.to_error_class(
               Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "is bad")
             )
           )
  end

  test "an error is transient when any error it wraps is" do
    trouble = Ash.Error.to_ash_error(postgrex("40P01", :deadlock_detected))
    invalid = Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "is bad")

    assert Transient.transient?(%Ash.Error.Unknown{errors: [invalid, trouble]})
    assert Transient.transient?(%Ash.Changeset{errors: [trouble]})
    refute Transient.transient?(%Ash.Changeset{errors: [invalid]})
  end
end
