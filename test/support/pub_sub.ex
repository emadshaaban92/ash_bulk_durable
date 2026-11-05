defmodule AshBulkDurable.Test.PubSub do
  @moduledoc """
  What `:pubsub_module` asks of an app: a `broadcast/3`. A registry stands in
  for one, since the library's tests run no web layer.
  """
  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  def subscribe(topic) do
    {:ok, _pid} = Registry.register(__MODULE__, topic, nil)
    :ok
  end

  def broadcast(topic, event, payload) do
    Registry.dispatch(__MODULE__, topic, fn subscribers ->
      for {pid, _value} <- subscribers, do: send(pid, {topic, event, payload})
    end)

    :ok
  end
end
