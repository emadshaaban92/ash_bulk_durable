defmodule Example.BulkActions do
  @moduledoc """
  The `ash_bulk_durable` bookkeeping. Authorization is on: the engine's own
  reads and writes skip it, and anyone else's go through the resources'
  policies.
  """
  use Ash.Domain

  resources do
    resource Example.BulkActions.BulkAction
    resource Example.BulkActions.Row
  end
end
