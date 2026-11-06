defmodule Example.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ExampleWeb.Telemetry,
        Example.Repo,
        {DNSCluster, query: Application.get_env(:example, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Example.PubSub},
        # Start to serve requests
        ExampleWeb.Endpoint,
        # Runs bulk actions. Last, so it stops first: the runs it lets finish
        # on shutdown still have the repo, and the PubSub and endpoint they
        # broadcast through.
        poller()
      ]
      |> Enum.reject(&is_nil/1)

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Example.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp poller do
    if Application.get_env(:example, :poller?, true), do: AshBulkDurable.Core.Poller
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ExampleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
