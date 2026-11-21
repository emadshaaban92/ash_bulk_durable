defmodule Mix.Tasks.AshBulkDurable.InstallTest do
  @moduledoc """
  `mix ash_bulk_durable.install` on an in-memory project with a repo and an
  application: what it writes, and that a second run changes nothing.
  """
  # Not async: igniter loads the project's config, `:ash_bulk_durable` keys
  # naming its modules included, into the application env while it works,
  # which would swap the config under any test running beside these.
  use ExUnit.Case, async: false

  import Igniter.Test

  defp project, do: test_project_with(%{})

  defp test_project_with(files) do
    test_project(
      files:
        Map.merge(
          %{
            "mix.exs" => mix_exs("[]"),
            ".formatter.exs" => """
            [import_deps: [:ash, :ash_postgres], inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]
            """,
            "lib/test/repo.ex" => """
            defmodule Test.Repo do
              use AshPostgres.Repo, otp_app: :test
            end
            """,
            "lib/test/application.ex" => """
            defmodule Test.Application do
              use Application

              def start(_type, _args) do
                children = [Test.Repo, TestWeb.Endpoint]
                Supervisor.start_link(children, strategy: :one_for_one)
              end
            end
            """,
            "config/config.exs" => """
            import Config

            config :test, ecto_repos: [Test.Repo]
            """
          },
          files
        )
    )
  end

  defp mix_exs(deps) do
    """
    defmodule Test.MixProject do
      use Mix.Project

      def project, do: [app: :test, version: "0.1.0", deps: deps()]

      def application, do: [mod: {Test.Application, []}, extra_applications: [:logger]]

      defp deps, do: #{deps}
    end
    """
  end

  defp install(igniter, argv \\ []),
    do: Igniter.compose_task(igniter, "ash_bulk_durable.install", argv)

  test "writes the domain, both resources, the owner, the config and the tree entry" do
    project()
    |> install()
    |> assert_creates("lib/test/bulk_actions.ex")
    |> assert_creates("lib/test/bulk_actions/bulk_action.ex")
    |> assert_creates("lib/test/bulk_actions/row.ex")
    |> assert_creates("lib/test/bulk_actions/owner.ex")
    |> assert_has_task("ash.codegen", ["add_bulk_actions"])
    |> assert_has_notice(&(&1 =~ "ash_bulk_durable is set up"))
    |> apply_igniter!()
    |> then(fn igniter ->
      assert source(igniter, "lib/test/bulk_actions.ex") =~ "resource Test.BulkActions.BulkAction"
      assert source(igniter, "lib/test/bulk_actions.ex") =~ "resource Test.BulkActions.Row"

      bulk_action = source(igniter, "lib/test/bulk_actions/bulk_action.ex")
      assert bulk_action =~ "extensions: [AshBulkDurable.Core.Resource.BulkAction]"
      assert bulk_action =~ "repo Test.Repo"
      assert bulk_action =~ "authorize_if expr(user_id == ^actor(:id))"

      assert source(igniter, "lib/test/bulk_actions/row.ex") =~
               "authorize_if expr(bulk_action.user_id == ^actor(:id))"

      owner = source(igniter, "lib/test/bulk_actions/owner.ex")
      assert owner =~ "@behaviour AshBulkDurable.Core.Owner"
      assert owner =~ "Ash.get!(Test.Accounts.User, id"

      config = source(igniter, "config/config.exs")
      assert config =~ "ash_domains: [Test.BulkActions]"
      assert config =~ "bulk_action_resource: Test.BulkActions.BulkAction"
      assert config =~ "row_resource: Test.BulkActions.Row"
      assert config =~ "owner_module: Test.BulkActions.Owner"
      assert config =~ "storage: AshBulkDurable.Storage.Local"

      assert config =~
               ~s(config :ash_bulk_durable, AshBulkDurable.Storage.Local, root: "priv/bulk_files")

      # Last, after the endpoint.
      assert source(igniter, "lib/test/application.ex") =~
               ~r/Test.Repo,\s+TestWeb.Endpoint,\s+AshBulkDurable\s*\]/
    end)
  end

  test "a second run changes nothing" do
    project()
    |> install()
    |> apply_igniter!()
    |> install()
    |> assert_unchanged()
  end

  test "takes the domain, repo and user from the options" do
    project()
    |> install(["--domain", "Test.Jobs", "--repo", "Test.OtherRepo", "--user", "Test.Member"])
    |> assert_creates("lib/test/jobs/bulk_action.ex")
    |> apply_igniter!()
    |> then(fn igniter ->
      assert source(igniter, "lib/test/jobs/bulk_action.ex") =~ "repo Test.OtherRepo"
      assert source(igniter, "lib/test/jobs/owner.ex") =~ "Ash.get!(Test.Member, id"
      assert source(igniter, "config/config.exs") =~ "owner_module: Test.Jobs.Owner"
    end)
  end

  test "adds the resources to a domain that is already there" do
    test_project_with(%{
      "lib/test/bulk_actions.ex" => """
      defmodule Test.BulkActions do
        use Ash.Domain, otp_app: :test

        resources do
          resource Test.BulkActions.Row
          resource Test.Other
        end
      end
      """
    })
    |> install()
    |> assert_has_patch("lib/test/bulk_actions.ex", """
    + |    resource Test.BulkActions.BulkAction
    """)
  end

  test "keeps config already set" do
    project()
    |> Igniter.Project.Config.configure(
      "config.exs",
      :ash_bulk_durable,
      [:owner_module],
      Test.MyOwner
    )
    |> install()
    |> apply_igniter!()
    |> then(fn igniter ->
      config = source(igniter, "config/config.exs")
      assert config =~ "owner_module: Test.MyOwner"
      refute config =~ "owner_module: Test.BulkActions.Owner"
    end)
  end

  test "the owner it writes reads the actor back, refuses a tenant, and needs an actor with an id" do
    igniter = project() |> install(["--user", "AshBulkDurable.Test.User"]) |> apply_igniter!()
    [{owner, _bytecode}] = Code.compile_string(source(igniter, "lib/test/bulk_actions/owner.ex"))
    sandbox = Ecto.Adapters.SQL.Sandbox.start_owner!(AshBulkDurable.Test.Repo, shared: true)

    try do
      user = AshBulkDurable.DataCase.create_super_user()

      assert owner.worker_key(%{actor: user}) == user.id

      assert {:ok, %{actor: %AshBulkDurable.Test.User{id: id}}} =
               owner.scope_from_worker_key(user.id, nil)

      assert id == user.id
      assert owner.scope_from_worker_key(Ash.UUID.generate(), nil) == {:error, :actor_not_found}

      assert owner.scope_from_worker_key(user.id, "t") ==
               {:error, {:tenant_access_not_checked, "t"}}

      assert_raise ArgumentError, ~r/needs a scope whose actor has an :id/, fn ->
        owner.worker_key(%{actor: nil})
      end
    after
      Ecto.Adapters.SQL.Sandbox.stop_owner(sandbox)
      :code.purge(owner)
      :code.delete(owner)
    end
  end

  test "adds no tree entry beside a poller the application starts by itself" do
    test_project_with(%{
      "lib/test/application.ex" => """
      defmodule Test.Application do
        use Application

        def start(_type, _args) do
          children = [Test.Repo, AshBulkDurable.Core.Poller]
          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end
      """
    })
    |> install()
    |> assert_unchanged("lib/test/application.ex")
    |> assert_has_notice(&(&1 =~ "already starts\n`AshBulkDurable.Core.Poller`"))
  end

  test "writes no disk store beside a storage already set" do
    project()
    |> Igniter.Project.Config.configure(
      "config.exs",
      :ash_bulk_durable,
      [:storage],
      AshBulkDurable.Storage.S3
    )
    |> install()
    |> apply_igniter!()
    |> then(fn igniter ->
      config = source(igniter, "config/config.exs")
      assert config =~ "storage: AshBulkDurable.Storage.S3"
      refute config =~ "AshBulkDurable.Storage.Local"
    end)
  end

  test "names the repo it picked among several" do
    test_project_with(%{
      "lib/test/other_repo.ex" => """
      defmodule Test.OtherRepo do
        use AshPostgres.Repo, otp_app: :test
      end
      """
    })
    |> install()
    |> assert_has_notice(&(&1 =~ "went in Test.OtherRepo." and &1 =~ "run again with `--repo`"))
    |> apply_igniter!()
    |> then(&assert(source(&1, "lib/test/bulk_actions/bulk_action.ex") =~ "repo Test.OtherRepo"))
  end

  test "adds a SAT solver for the policies when the app has none" do
    solver = if match?({_, :nt}, :os.type()), do: "simple_sat", else: "picosat_elixir"

    project()
    |> install()
    |> assert_has_notice(&(&1 =~ "need a SAT solver" and &1 =~ solver))
    |> apply_igniter!()
    |> then(&assert(source(&1, "mix.exs") =~ ~s({:#{solver}, "~> 0.)))
  end

  test "adds no SAT solver beside one already there" do
    test_project_with(%{
      "mix.exs" => mix_exs(~s([{:simple_sat, "~> 0.1"}]))
    })
    |> install()
    |> assert_unchanged("mix.exs")
  end

  test "stops with an issue when there is no repo" do
    test_project()
    |> install()
    |> assert_has_issue(&(&1 =~ "needs an Ecto repo"))
  end

  defp source(igniter, path) do
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end
end
