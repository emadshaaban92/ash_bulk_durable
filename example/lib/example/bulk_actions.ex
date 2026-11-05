defmodule Example.BulkActions do
  @moduledoc """
  The `ash_bulk_durable` bookkeeping. The worker writes progress with no user
  behind it, so authorization is opt-in here.
  """
  use Ash.Domain

  resources do
    resource Example.BulkActions.BulkAction
    resource Example.BulkActions.Row
  end

  authorization do
    require_actor? false
    authorize :when_requested
  end
end
