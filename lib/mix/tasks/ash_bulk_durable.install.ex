if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshBulkDurable.Install do
    @example "mix ash_bulk_durable.install --domain MyApp.BulkActions --user MyApp.Accounts.User"

    @moduledoc """
    Sets up `ash_bulk_durable` in an Ash app with an Ecto repo, as the README's
    "Setup" does by hand. Run it with `mix ash_bulk_durable.install` once it is a
    dependency, with igniter beside it, or add both at once with
    `mix igniter.install ash_bulk_durable@github:emadshaaban92/ash_bulk_durable`.

    It writes:

      * a domain with the two resources, a bulk action and a row, each with the
        README's policies (owners read their own, nothing more), added to
        `:ash_domains`;
      * an owner module, `AshBulkDurable.Core.Owner`, that keeps the actor's
        id and reads the actor again by it. It refuses any bulk action
        submitted in a tenant until you say who may act there;
      * the `:ash_bulk_durable` config naming them, with
        `AshBulkDurable.Storage.Local` keeping staged files under
        `priv/bulk_files` unless a `:storage` is set already;
      * `AshBulkDurable` last in the application's supervision tree, unless the
        application already starts `AshBulkDurable.Core.Poller` by itself, when
        it says so instead: the two would start the same poller;
      * a migration for the two tables, through `mix ash.codegen`.

    It is safe to run again: a module that is already there, a config key
    already set and a tree entry already present are left as they are.

    ## Example

    ```sh
    #{@example}
    ```

    ## Options

      * `--domain` — the domain to put the resources in, `<App>.BulkActions` by
        default. Its resources are `<Domain>.BulkAction` and `<Domain>.Row`, its
        owner `<Domain>.Owner`.
      * `--repo` — the repo the two tables live in; every resource a bulk
        action writes must be in it. By default the app's only repo, or the
        first one found.
      * `--user` — the resource the owner reads the actor from by id,
        `<App>.Accounts.User` by default.
    """
    @shortdoc "Sets up ash_bulk_durable: a domain, two resources, an owner, config and the tree entry"

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :ash_bulk_durable,
        example: @example,
        schema: [domain: :string, repo: :string, user: :string],
        aliases: [d: :domain, r: :repo, u: :user]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      opts = igniter.args.options
      otp_app = Igniter.Project.Application.app_name(igniter)

      domain = module_option(igniter, opts[:domain], "BulkActions")
      user = module_option(igniter, opts[:user], "Accounts.User")
      bulk_action = Module.concat(domain, BulkAction)
      row = Module.concat(domain, Row)
      owner = Module.concat(domain, Owner)

      case repo(igniter, opts[:repo]) do
        {igniter, nil} ->
          Igniter.add_issue(igniter, """
          ash_bulk_durable needs an Ecto repo for its tables, and none was found.
          Install ash_postgres first (`mix igniter.install ash_postgres`), or pass
          `--repo MyApp.Repo`.
          """)

        {igniter, repo} ->
          igniter
          |> create_domain(otp_app, domain, [bulk_action, row])
          |> create_new(bulk_action, bulk_action_contents(domain, repo))
          |> create_new(row, row_contents(domain, repo))
          |> create_new(owner, owner_contents(user))
          |> configure(bulk_action, row, owner)
          |> add_tree_entry()
          |> Ash.Igniter.codegen("add_bulk_actions")
          |> Igniter.add_notice(notice(owner, user))
      end
    end

    defp module_option(igniter, nil, suffix),
      do: Igniter.Project.Module.module_name(igniter, suffix)

    defp module_option(_igniter, name, _suffix), do: Igniter.Project.Module.parse(name)

    defp repo(igniter, nil) do
      case Igniter.Libs.Ecto.list_repos(igniter) do
        {igniter, []} ->
          {igniter, nil}

        {igniter, [repo]} ->
          {igniter, repo}

        {igniter, [repo | _] = repos} ->
          {Igniter.add_notice(igniter, """
           ash_bulk_durable: of the repos #{Enum.map_join(repos, ", ", &inspect/1)}, its tables
           went in #{inspect(repo)}. Every resource a bulk action writes must be in the same
           repo; run again with `--repo` to pick another.
           """), repo}
      end
    end

    defp repo(igniter, name), do: {igniter, Igniter.Project.Module.parse(name)}

    # An existing domain only gains the resources it lacks.
    defp create_domain(igniter, otp_app, domain, resources) do
      resource_lines = Enum.map_join(resources, "\n", &"resource #{inspect(&1)}")

      igniter
      |> then(fn igniter ->
        case Igniter.Project.Module.module_exists(igniter, domain) do
          {true, igniter} ->
            Enum.reduce(resources, igniter, &add_resource(&2, domain, &1))

          {false, igniter} ->
            Igniter.Project.Module.create_module(igniter, domain, """
            use Ash.Domain, otp_app: #{inspect(otp_app)}

            resources do
              #{resource_lines}
            end
            """)
        end
      end)
      |> Igniter.Project.Config.configure(
        "config.exs",
        otp_app,
        [:ash_domains],
        [domain],
        updater: &Igniter.Code.List.append_new_to_list(&1, domain)
      )
    end

    defp add_resource(igniter, domain, resource) do
      Igniter.Project.Module.find_and_update_module!(igniter, domain, fn zipper ->
        with {:ok, zipper} <-
               Igniter.Code.Function.move_to_function_call_in_current_scope(zipper, :resources, 1),
             {:ok, zipper} <- Igniter.Code.Common.move_to_do_block(zipper) do
          {:ok, add_new_resource(zipper, resource)}
        else
          :error ->
            {:warning,
             "#{inspect(domain)} has no `resources` block: add `resource #{inspect(resource)}` to it."}
        end
      end)
    end

    defp add_new_resource(zipper, resource) do
      case Igniter.Code.Function.move_to_function_call_in_current_scope(
             zipper,
             :resource,
             [1, 2],
             &Igniter.Code.Function.argument_equals?(&1, 0, resource)
           ) do
        {:ok, _found} -> zipper
        :error -> Igniter.Code.Common.add_code(zipper, "resource #{inspect(resource)}")
      end
    end

    defp create_new(igniter, module, contents),
      do:
        Igniter.Project.Module.find_and_update_or_create_module(
          igniter,
          module,
          contents,
          &{:ok, &1}
        )

    # The disk store's root only with the disk store, not beside a storage the
    # app already chose.
    defp configure(igniter, bulk_action, row, owner) do
      storage =
        if Igniter.Project.Config.configures_key?(
             igniter,
             "config.exs",
             :ash_bulk_durable,
             :storage
           ),
           do: [],
           else: [
             {[:storage], AshBulkDurable.Storage.Local},
             {[AshBulkDurable.Storage.Local, :root], "priv/bulk_files"}
           ]

      [
        {[:bulk_action_resource], bulk_action},
        {[:row_resource], row},
        {[:owner_module], owner}
        | storage
      ]
      |> Enum.reduce(igniter, fn {path, value}, igniter ->
        Igniter.Project.Config.configure_new(
          igniter,
          "config.exs",
          :ash_bulk_durable,
          path,
          value
        )
      end)
    end

    # A poller already in the tree, as the README once had it (or under a
    # helper of the application module's), would start twice beside
    # `AshBulkDurable`, under one name, and stop the app booting.
    defp add_tree_entry(igniter) do
      case standalone_poller(igniter) do
        {igniter, nil} ->
          Igniter.Project.Application.add_new_child(igniter, AshBulkDurable,
            after: fn _ -> true end
          )

        {igniter, application} ->
          Igniter.add_notice(igniter, """
          ash_bulk_durable: #{inspect(application)} already starts
          `AshBulkDurable.Core.Poller`, so `AshBulkDurable` was not added to its tree:
          the two would start the same poller. To use the one entry, replace the
          poller with `AshBulkDurable` (its options go under `poller:`).
          """)
      end
    end

    defp standalone_poller(igniter) do
      application =
        case Igniter.Project.Application.app_module(igniter) do
          {module, _args} -> module
          module -> module
        end

      with true <- is_atom(application) and not is_nil(application),
           {:ok, {igniter, _source, zipper}} <-
             Igniter.Project.Module.find_module(igniter, application) do
        poller? =
          Sourceror.Zipper.find(zipper, fn node ->
            Igniter.Code.Common.nodes_equal?(node, AshBulkDurable.Core.Poller)
          end)

        {igniter, if(poller?, do: application)}
      else
        {:error, igniter} -> {igniter, nil}
        false -> {igniter, nil}
      end
    end

    defp bulk_action_contents(domain, repo) do
      """
      @moduledoc "A bulk action: one Ash action run durably over many rows."

      use Ash.Resource,
        domain: #{inspect(domain)},
        data_layer: AshPostgres.DataLayer,
        notifiers: [Ash.Notifier.PubSub],
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshBulkDurable.Core.Resource.BulkAction]

      postgres do
        table "bulk_actions"
        repo #{inspect(repo)}

        identity_wheres_to_sql one_unresolved_per_user:
                                 "status IN ('queued', 'running', 'completed_with_errors')"
      end

      # The engine's own reads and writes skip these policies, so they only
      # decide what everyone else may do: read their own bulk actions.
      policies do
        policy action_type(:read) do
          authorize_if expr(user_id == ^actor(:id))
        end
      end
      """
    end

    defp row_contents(domain, repo) do
      """
      @moduledoc "One row of a bulk action: a target and an input."

      use Ash.Resource,
        domain: #{inspect(domain)},
        data_layer: AshPostgres.DataLayer,
        authorizers: [Ash.Policy.Authorizer],
        extensions: [AshBulkDurable.Core.Resource.Row]

      postgres do
        table "bulk_action_rows"
        repo #{inspect(repo)}
      end

      policies do
        policy action_type(:read) do
          authorize_if expr(bulk_action.user_id == ^actor(:id))
        end
      end
      """
    end

    defp owner_contents(user) do
      """
      @moduledoc \"\"\"
      Who a bulk action belongs to, and how the worker acts as them again: the
      actor's id is kept, and the worker reads the actor by it when it runs.

      A bulk action submitted in a tenant is refused until you check here that
      its owner may still act there (a membership, say): every row that names
      no tenant of its own is written in that tenant, whatever the scope says.
      See `AshBulkDurable.Core.Owner`.
      \"\"\"
      @behaviour AshBulkDurable.Core.Owner

      # The bulk action's `user_id`, a UUID.
      @impl true
      def worker_key(scope) do
        case Ash.Scope.ToOpts.get_actor(scope) do
          {:ok, %{id: id}} -> id
          _none -> raise ArgumentError, "a bulk action needs a scope whose actor has an :id"
        end
      end

      # Raises when the read fails, which counts as a setup error that may pass.
      @impl true
      def scope_from_worker_key(id, nil) do
        case Ash.get!(#{inspect(user)}, id, authorize?: false, not_found_error?: false) do
          nil -> {:error, :actor_not_found}
          actor -> {:ok, %{actor: actor}}
        end
      end

      def scope_from_worker_key(_id, tenant), do: {:error, {:tenant_access_not_checked, tenant}}
      """
    end

    defp notice(owner, user) do
      """
      ash_bulk_durable is set up. Before submitting a bulk action:

        * Check #{inspect(owner)}: it reads the actor from #{inspect(user)} by a
          UUID id, and refuses a bulk action submitted in a tenant until you
          say who may act there.
        * Point `AshBulkDurable.Storage.Local`'s `:root` at a lasting directory in
          production, one every node shares, or use `AshBulkDurable.Storage.S3`
          (see the README).
        * Run `mix ash.migrate` for the two new tables.
      """
    end
  end
else
  defmodule Mix.Tasks.AshBulkDurable.Install do
    @moduledoc "Sets up ash_bulk_durable. Needs igniter in the app's deps."
    @shortdoc @moduledoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_bulk_durable.install' needs igniter. Add it to your deps:

          {:igniter, "~> 0.8", only: [:dev, :test]}

      then run `mix deps.get` and `mix ash_bulk_durable.install` again.
      """)

      exit({:shutdown, 1})
    end
  end
end
