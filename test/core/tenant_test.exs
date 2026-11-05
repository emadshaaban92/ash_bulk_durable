defmodule AshBulkDurable.Core.TenantTest do
  @moduledoc """
  Each row acts in its target's tenant: a value, a lookup the core resolves,
  or, naming none, the bulk action's. The worker resolves a chunk's input
  references tenant by tenant, and an all-or-nothing bulk action spanning
  tenants is one transaction.

  The package's tenant support is proven against a test-only resource (`Widget`, attribute
  multitenancy by `Workspace`, in `test/support`). Their tables are created
  inside the test's sandbox transaction and vanish with it.
  """
  use AshBulkDurable.DataCase, async: true

  require Ash.Query

  defmodule ExpiringResolver do
    @moduledoc """
    Reports each resolving to the test, and asks it whether a kept value still
    holds, as `AshBulkDurable.Core.Resolver.lost/2` lets a stored file's do.
    """
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, %{tenant: tenant}) do
      send(List.last(Process.get(:"$callers", [self()])), {:prepared, tenant})
      {:ok, nil}
    end

    @impl true
    def resolve(value, nil, %{tenant: tenant}) do
      send(List.last(Process.get(:"$callers", [self()])), {:resolved, tenant, value})
      {:ok, value}
    end

    @impl true
    def finish(nil), do: :ok

    @impl true
    def after_write(_record, _resolved, _context) do
      # Set in the test's own process, which the run is not.
      test = List.last(Process.get(:"$callers", [self()]))
      {:dictionary, dictionary} = Process.info(test, :dictionary)
      if dictionary[:refuse_writes], do: {:error, "refused"}, else: :ok
    end

    @impl true
    def lost(resolved, %{tenant: tenant, staged_files: staged_files}) do
      send(
        List.last(Process.get(:"$callers", [self()])),
        {:asked, tenant, Enum.sort(resolved), staged_files}
      )

      Enum.filter(resolved, &String.starts_with?(&1, "expired"))
    end
  end

  alias AshBulkDurable.Core.{Runner, Worker}
  alias AshBulkDurable.Test.{Gadget, Widget, Workspace}
  alias AshBulkDurable.Test.{BulkAction, Row}

  setup %{super_user: user} do
    AshBulkDurable.Test.Repo.query!(
      "CREATE TABLE bulk_tenant_test_workspaces (id uuid PRIMARY KEY, code text NOT NULL)"
    )

    AshBulkDurable.Test.Repo.query!("""
    CREATE TABLE bulk_tenant_test_widgets (
      id uuid PRIMARY KEY,
      workspace_id uuid NOT NULL,
      name text NOT NULL,
      parent_id uuid
    )
    """)

    [w1, w2] = Enum.map(["W1", "W2"], &Ash.create!(Workspace, %{code: &1}))

    # A root of the same name in each workspace: a row looking it up finds
    # its own workspace's.
    roots =
      Map.new([w1, w2], fn workspace ->
        {workspace.id, Ash.create!(Widget, %{name: "Root"}, tenant: workspace.id)}
      end)

    %{user: user, w1: w1, w2: w2, roots: roots}
  end

  defp run!(user, action, rows, opts \\ []) do
    {:ok, bulk_action} =
      AshBulkDurable.Core.create(
        Widget,
        action,
        rows,
        Keyword.merge([scope: AshBulkDurable.Test.Scope.new(actor: user), chunk_size: 10], opts)
      )

    assert :ok = Worker.run_now(bulk_action.id)

    {Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending]),
     rows(bulk_action)}
  end

  defp rows(bulk_action) do
    Row
    |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
    |> Ash.Query.sort(row_index: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp widgets(workspace) do
    Widget
    |> Ash.Query.filter(name != "Root")
    |> Ash.read!(tenant: workspace.id)
    |> Map.new(&{&1.name, &1})
  end

  defp root_lookup, do: {:lookup, Widget, :name, "Root"}
  defp workspace_lookup(code), do: {:lookup, Workspace, :code, code}

  test "a row acts in its tenant, given or looked up, else the bulk action's; lookups resolve there",
       ctx do
    rows = [
      %{target: %{tenant: ctx.w1.id}, input: %{name: "given", parent_id: root_lookup()}},
      %{
        target: %{tenant: workspace_lookup("W2")},
        input: %{name: "looked up", parent_id: root_lookup()}
      },
      %{input: %{name: "default", parent_id: root_lookup()}}
    ]

    {bulk_action, stored} = run!(ctx.user, :create, rows, tenant: ctx.w2.id)

    assert bulk_action.status == :completed
    assert Enum.map(stored, & &1.resolved_tenant) == [nil, ctx.w2.id, nil]

    assert %{"given" => given} = widgets(ctx.w1)
    assert %{"looked up" => looked_up, "default" => default} = widgets(ctx.w2)

    assert given.parent_id == ctx.roots[ctx.w1.id].id
    assert looked_up.parent_id == ctx.roots[ctx.w2.id].id
    assert default.parent_id == ctx.roots[ctx.w2.id].id
  end

  test "a tenant lookup matching nothing fails its row alone", ctx do
    rows = [
      %{target: %{tenant: workspace_lookup("NOPE")}, input: %{name: "lost"}},
      %{target: %{tenant: ctx.w1.id}, input: %{name: "kept"}}
    ]

    {bulk_action, [lost, kept]} = run!(ctx.user, :create, rows)

    assert bulk_action.status == :completed_with_errors
    assert lost.status == :failed
    assert Enum.map_join(lost.error, & &1.message) =~ ~s(no Workspace matches code = "NOPE")
    assert kept.status == :succeeded
    assert Map.keys(widgets(ctx.w1)) == ["kept"]
  end

  test "a chunk's resolvers are prepared once in each tenant, however many rows it has there",
       ctx do
    rows =
      for {name, workspace} <- [{"a", ctx.w1}, {"b", ctx.w2}, {"c", ctx.w1}, {"d", ctx.w2}] do
        %{target: %{tenant: workspace.id}, input: %{name: {:resolve, ExpiringResolver, name}}}
      end

    {bulk_action, _rows} = run!(ctx.user, :create, rows)
    assert bulk_action.status == :completed

    {w1, w2} = {ctx.w1.id, ctx.w2.id}
    assert_received {:prepared, ^w1}
    assert_received {:prepared, ^w2}
    refute_received {:prepared, _tenant}

    assert widgets(ctx.w1) |> Map.keys() |> Enum.sort() == ["a", "c"]
    assert widgets(ctx.w2) |> Map.keys() |> Enum.sort() == ["b", "d"]
  end

  test "an update finds its record in the row's tenant", ctx do
    rows = [
      %{
        target: %{tenant: workspace_lookup("W2"), lookup: %{name: "Root"}},
        input: %{name: "Renamed"}
      }
    ]

    {bulk_action, [row]} = run!(ctx.user, :update, rows)

    assert bulk_action.status == :completed
    assert row.record_id == ctx.roots[ctx.w2.id].id
    assert Map.keys(widgets(ctx.w2)) == ["Renamed"]
    assert widgets(ctx.w1) == %{}
  end

  describe "a value kept while a row waited for a correction" do
    # A parent that isn't a UUID refuses the row at the write, past the resolve.
    defp parked(name, workspace) do
      %{target: %{tenant: workspace.id}, input: %{name: resolving(name), parent_id: "nope"}}
    end

    defp resolving(name), do: {:resolve, ExpiringResolver, name}

    defp fixed(%{input: input}), do: %{input: %{input | parent_id: nil}}

    test "is lost in its own tenant, each tenant's resolver asked once, and resolves again",
         ctx do
      {bulk_action, stored} =
        run!(ctx.user, :create, [
          parked("expired one", ctx.w1),
          parked("held", ctx.w1),
          parked("expired two", ctx.w2)
        ])

      assert bulk_action.status == :completed_with_errors
      flush_resolved()

      {:ok, _retried} =
        AshBulkDurable.Core.retry(bulk_action,
          scope: AshBulkDurable.Test.Scope.new(actor: ctx.user),
          rows: Map.new(stored, &{&1.id, fixed(&1)})
        )

      assert :ok = Worker.run_now(bulk_action.id)

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).status == :completed

      {w1, w2} = {ctx.w1.id, ctx.w2.id}
      assert_received {:asked, ^w1, ["expired one", "held"], staged} when staged == %{}
      assert_received {:asked, ^w2, ["expired two"], staged} when staged == %{}
      refute_received {:asked, _tenant, _values, _staged}

      assert_received {:resolved, ^w1, "expired one"}
      assert_received {:resolved, ^w2, "expired two"}
      refute_received {:resolved, _tenant, "held"}

      assert %{"expired one" => _, "held" => _} = widgets(ctx.w1)
      assert %{"expired two" => _} = widgets(ctx.w2)
    end

    test "goes alone: what else the row resolved stays kept", ctx do
      root = ctx.roots[ctx.w1.id].id
      input = %{name: resolving("expired name"), parent_id: resolving(root)}

      Process.put(:refuse_writes, true)
      {bulk_action, _stored} = run!(ctx.user, :create, [%{input: input}], tenant: ctx.w1.id)
      assert bulk_action.status == :completed_with_errors
      flush_resolved()

      Process.delete(:refuse_writes)
      {:ok, _retried} = AshBulkDurable.Core.retry(bulk_action, scope: scope(ctx.user))
      assert :ok = Worker.run_now(bulk_action.id)

      assert_received {:resolved, _tenant, "expired name"}
      refute_received {:resolved, _tenant, ^root}
      assert %{"expired name" => %{parent_id: ^root}} = widgets(ctx.w1)
    end

    test "on a row a crash left resolved takes it back through the resolve phase", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.Core.create(Widget, :create, [%{input: %{name: resolving("expired")}}],
          scope: scope(ctx.user),
          tenant: ctx.w1.id,
          chunk_size: 10
        )

      settings = Runner.settings(bulk_action, scope(ctx.user), %{})

      [row] = rows(bulk_action)

      assert %{status: :resolved} =
               Ash.update!(row, %{},
                 action: :resolve,
                 authorize?: false,
                 context: %{
                   ash_bulk_durable: %{settings: settings, resolvers: %{ExpiringResolver => nil}}
                 }
               )

      flush_resolved()
      assert :ok = Worker.run_now(bulk_action.id)

      assert_received {:resolved, _tenant, "expired"}

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).status == :completed

      assert %{"expired" => _} = widgets(ctx.w1)
    end

    test "held by a shared input resolves again on every row that kept it", ctx do
      shared = %{name: resolving("expired shared"), parent_id: "nope"}

      {bulk_action, _stored} =
        run!(ctx.user, :create, [%{}, %{}], tenant: ctx.w1.id, input: shared)

      assert bulk_action.status == :completed_with_errors
      flush_resolved()

      {:ok, _retried} =
        AshBulkDurable.Core.retry(bulk_action,
          scope: AshBulkDurable.Test.Scope.new(actor: ctx.user),
          input: %{shared | parent_id: nil}
        )

      assert :ok = Worker.run_now(bulk_action.id)

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).status == :completed

      w1 = ctx.w1.id
      assert_received {:resolved, ^w1, "expired shared"}
      assert_received {:resolved, ^w1, "expired shared"}
    end

    defp scope(user), do: AshBulkDurable.Test.Scope.new(actor: user)

    defp flush_resolved do
      receive do
        {:resolved, _tenant, _value} -> flush_resolved()
      after
        0 -> :ok
      end
    end
  end

  describe "a shared input" do
    test "a row with none of its own runs with it; a row's own replaces it, keeping nothing of it",
         ctx do
      rows = [%{}, %{input: %{}}, %{input: %{name: "own"}}]
      shared = %{name: "shared", parent_id: root_lookup()}

      {bulk_action, stored} = run!(ctx.user, :create, rows, tenant: ctx.w1.id, input: shared)

      assert bulk_action.status == :completed
      assert bulk_action.input == shared
      assert Enum.map(stored, & &1.input) == [nil, nil, %{name: "own"}]
      assert Enum.map(stored, & &1.status) == [:succeeded, :succeeded, :succeeded]

      records = Ash.read!(Widget, tenant: ctx.w1.id)
      root_id = ctx.roots[ctx.w1.id].id

      assert [^root_id, ^root_id] =
               records |> Enum.filter(&(&1.name == "shared")) |> Enum.map(& &1.parent_id)

      assert [nil] = records |> Enum.filter(&(&1.name == "own")) |> Enum.map(& &1.parent_id)
    end

    test "records selected across tenants act in theirs, a shared lookup finding each one's",
         ctx do
      records =
        Enum.map([ctx.w1, ctx.w2], fn workspace ->
          Ash.create!(Widget, %{name: "Selected"}, tenant: workspace.id)
        end)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(
          records,
          :update,
          %{name: "Shared", parent_id: root_lookup()},
          scope: AshBulkDurable.Test.Scope.new(actor: ctx.user)
        )

      assert :ok = Worker.run_now(bulk_action.id)

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).status == :completed

      assert Enum.map(rows(bulk_action), & &1.target.tenant) == [ctx.w1.id, ctx.w2.id]

      assert %{"Shared" => first} = widgets(ctx.w1)
      assert %{"Shared" => second} = widgets(ctx.w2)
      assert first.parent_id == ctx.roots[ctx.w1.id].id
      assert second.parent_id == ctx.roots[ctx.w2.id].id
    end

    test "a query's rows act in the tenant it was read in; IDs in the call's", ctx do
      scope = AshBulkDurable.Test.Scope.new(actor: ctx.user)
      queried = Ash.create!(Widget, %{name: "Queried"}, tenant: ctx.w1.id)
      by_id = Ash.create!(Widget, %{name: "By ID"}, tenant: ctx.w2.id)

      {:ok, bulk_action} =
        Widget
        |> Ash.Query.filter(name == "Queried")
        |> Ash.Query.set_tenant(ctx.w1.id)
        |> AshBulkDurable.bulk_update(:update, %{name: "From a query"}, scope: scope)

      assert [row] = rows(bulk_action)
      assert row.target == %{lookup: %{id: queried.id}, tenant: ctx.w1.id}
      assert :ok = Worker.run_now(bulk_action.id)
      assert Map.keys(widgets(ctx.w1)) == ["From a query"]

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([by_id.id], :update, %{name: "From an ID"},
          resource: Widget,
          tenant: ctx.w2.id,
          scope: scope
        )

      assert :ok = Worker.run_now(bulk_action.id)
      assert Map.keys(widgets(ctx.w2)) == ["From an ID"]
    end

    test "a record multitenant by context acts in the tenant it was read in", ctx do
      [first, second] =
        Enum.map(1..2, fn _n ->
          tenant = "tenant-#{System.unique_integer([:positive])}"
          Ash.create!(Gadget, %{name: "Selected"}, tenant: tenant)
          tenant
        end)

      selected = Enum.flat_map([first, second], &Ash.read!(Gadget, tenant: &1))

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update(selected, :update, %{name: "Shared"},
          scope: AshBulkDurable.Test.Scope.new(actor: ctx.user)
        )

      assert :ok = Worker.run_now(bulk_action.id)

      assert [%{name: "Shared"}] = Ash.read!(Gadget, tenant: first)
      assert [%{name: "Shared"}] = Ash.read!(Gadget, tenant: second)
    end
  end

  describe "a sheet's tenant column" do
    defp tenant_column(column \\ "Workspace"),
      do: %{resource: Workspace, identity: :code, csv_col: column}

    defp sheet(rows) do
      %AshBulkDurable.Sheet{
        headers: rows |> List.first() |> Map.keys(),
        rows: rows
      }
    end

    defp create_sheet!(user, rows, opts \\ []) do
      {:ok, bulk_action} =
        rows
        |> sheet()
        |> AshBulkDurable.bulk_create(
          Widget,
          :create,
          Keyword.merge(
            [
              scope: scope(user),
              mapping: [
                columns: %{name: "Name", parent_id: "Parent"},
                rel_identities: %{},
                tenant_mapping: tenant_column()
              ]
            ],
            opts
          )
        )

      assert :ok = Worker.run_now(bulk_action.id)

      {Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending]),
       rows(bulk_action)}
    end

    test "a create puts each row in the workspace its cell names; a miss fails that row alone",
         ctx do
      {bulk_action, [one, two, lost, blank]} =
        create_sheet!(ctx.user, [
          %{"Name" => "one", "Parent" => "", "Workspace" => "W1"},
          %{"Name" => "two", "Parent" => "", "Workspace" => "W2"},
          %{"Name" => "lost", "Parent" => "", "Workspace" => "NOPE"},
          %{"Name" => "blank", "Parent" => "", "Workspace" => ""}
        ])

      assert bulk_action.status == :completed_with_errors
      assert {one.status, two.status} == {:succeeded, :succeeded}
      assert lost.status == :failed
      assert Enum.map_join(lost.error, & &1.message) =~ ~s(no Workspace matches code = "NOPE")
      # A row that names no workspace is a mistake, not "wherever I am acting".
      assert blank.status == :failed

      assert Map.keys(widgets(ctx.w1)) == ["one"]
      assert Map.keys(widgets(ctx.w2)) == ["two"]
    end

    test "a blank cell doesn't fall back to the workspace the owner acts in", ctx do
      {bulk_action, [blank]} =
        create_sheet!(
          ctx.user,
          [%{"Name" => "blank", "Parent" => "", "Workspace" => ""}],
          tenant: ctx.w1.id
        )

      assert bulk_action.status == :completed_with_errors
      assert blank.status == :failed
      assert widgets(ctx.w1) == %{}
    end

    test "an update finds its record in the workspace its cell names", ctx do
      parent = ctx.roots[ctx.w1.id].id
      {bulk_action, [row]} = update_sheet!(ctx.user, "W2", parent)

      assert bulk_action.status == :completed
      assert row.record_id == ctx.roots[ctx.w2.id].id
      assert Ash.reload!(ctx.roots[ctx.w2.id], tenant: ctx.w2.id).parent_id == parent
      assert Ash.reload!(ctx.roots[ctx.w1.id], tenant: ctx.w1.id).parent_id == nil
    end

    test "a record not in the cell's workspace fails, and correcting the cell finds it", ctx do
      Ash.update!(ctx.roots[ctx.w2.id], %{name: "Only in W2"}, tenant: ctx.w2.id)
      other = Ash.create!(Widget, %{name: "Only in W1"}, tenant: ctx.w1.id)

      {bulk_action, [row]} = update_sheet!(ctx.user, "W2", other.id, "Only in W1")
      assert row.status == :failed
      assert Ash.reload!(other, tenant: ctx.w1.id).parent_id == nil

      errors = AshBulkDurable.errors_sheet(bulk_action)
      assert [%{"tenant.code" => "W2", "name" => "Only in W1"} = cells] = errors.rows

      {:ok, _retried} =
        AshBulkDurable.retry(
          bulk_action,
          %{errors | rows: [%{cells | "tenant.code" => "W1"}]},
          scope: scope(ctx.user)
        )

      assert :ok = Worker.run_now(bulk_action.id)
      assert Ash.reload!(other, tenant: ctx.w1.id).parent_id == other.id
    end

    defp update_sheet!(user, workspace, parent, name \\ "Root") do
      {:ok, bulk_action} =
        [%{"Name" => name, "Parent" => parent, "Workspace" => workspace}]
        |> sheet()
        |> AshBulkDurable.update_many(Widget, :update,
          scope: scope(user),
          identity: :name,
          mapping: [
            columns: %{name: "Name", parent_id: "Parent"},
            tenant_mapping: tenant_column()
          ]
        )

      assert :ok = Worker.run_now(bulk_action.id)

      {Ash.get!(BulkAction, bulk_action.id, authorize?: false, load: [:rows_done, :rows_pending]),
       rows(bulk_action)}
    end

    test "an errors sheet shows the cell, and correcting it runs the row in the corrected one",
         ctx do
      {bulk_action, [_one, lost]} =
        create_sheet!(ctx.user, [
          %{"Name" => "one", "Parent" => "", "Workspace" => "W1"},
          %{"Name" => "lost", "Parent" => "", "Workspace" => "W3"}
        ])

      errors = AshBulkDurable.errors_sheet(bulk_action)
      assert "tenant.code" in errors.headers
      assert [%{"row_id" => row_id, "tenant.code" => "W3"} = cells] = errors.rows
      assert row_id == lost.id

      corrected = %{errors | rows: [%{cells | "tenant.code" => "W2"}]}
      {:ok, _retried} = AshBulkDurable.retry(bulk_action, corrected, scope: scope(ctx.user))
      assert :ok = Worker.run_now(bulk_action.id)

      assert Ash.get!(BulkAction, bulk_action.id,
               authorize?: false,
               load: [:rows_done, :rows_pending]
             ).status == :completed

      assert Map.keys(widgets(ctx.w2)) == ["lost"]
      assert Map.keys(widgets(ctx.w1)) == ["one"]
    end

    test "an untouched errors sheet leaves the row in the workspace it named", ctx do
      {bulk_action, _rows} =
        create_sheet!(ctx.user, [%{"Name" => "", "Parent" => "", "Workspace" => "W2"}])

      errors = AshBulkDurable.errors_sheet(bulk_action)
      assert [%{"tenant.code" => "W2"} = cells] = errors.rows

      corrected = %{errors | rows: [Map.put(cells, "name", "named")]}
      {:ok, _retried} = AshBulkDurable.retry(bulk_action, corrected, scope: scope(ctx.user))
      assert :ok = Worker.run_now(bulk_action.id)

      assert Map.keys(widgets(ctx.w2)) == ["named"]
      assert widgets(ctx.w1) == %{}
    end

    test "all or nothing, a cell naming no workspace stops it at that row, writing none", ctx do
      {bulk_action, _rows} =
        create_sheet!(
          ctx.user,
          [
            %{"Name" => "one", "Parent" => "", "Workspace" => "W1"},
            %{"Name" => "lost", "Parent" => "", "Workspace" => "NOPE"}
          ],
          mode: :all_or_nothing
        )

      assert bulk_action.status == :failed
      assert bulk_action.result["row_index"] == 1
      assert widgets(ctx.w1) == %{}
    end
  end

  describe "bulk_create rows naming their tenant" do
    test "a value, a lookup, or neither", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(
          [
            {%{tenant: ctx.w1.id}, %{name: "given"}},
            {%{tenant: workspace_lookup("W2")}, %{name: "looked up"}},
            %{name: "default"}
          ],
          Widget,
          :create,
          scope: scope(ctx.user),
          tenant: ctx.w2.id
        )

      assert :ok = Worker.run_now(bulk_action.id)

      assert Map.keys(widgets(ctx.w1)) == ["given"]
      assert widgets(ctx.w2) |> Map.keys() |> Enum.sort() == ["default", "looked up"]
    end
  end

  describe "correcting a row's tenant" do
    test "retries it there, what it resolved in the old tenant resolved again", ctx do
      {bulk_action, [row]} =
        run!(ctx.user, :create, [
          %{
            target: %{tenant: workspace_lookup("W1")},
            input: %{name: nil, parent_id: root_lookup()}
          }
        ])

      assert row.status == :failed
      assert row.resolved_tenant == ctx.w1.id
      assert row.resolved_data["parent_id"] == ctx.roots[ctx.w1.id].id

      {:ok, _retried} =
        AshBulkDurable.retry(bulk_action,
          scope: scope(ctx.user),
          rows: %{
            row.id => %{
              tenant: workspace_lookup("W2"),
              input: %{name: "moved", parent_id: root_lookup()}
            }
          }
        )

      assert :ok = Worker.run_now(bulk_action.id)

      assert %{"moved" => moved} = widgets(ctx.w2)
      assert moved.parent_id == ctx.roots[ctx.w2.id].id
      assert widgets(ctx.w1) == %{}
    end

    test "through retry_row takes the row alone", ctx do
      {_bulk_action, [row]} =
        run!(ctx.user, :create, [%{target: %{tenant: ctx.w1.id}, input: %{}}])

      {:ok, _retried} =
        AshBulkDurable.retry_row(row,
          scope: scope(ctx.user),
          tenant: ctx.w2.id,
          input: %{name: "moved"}
        )

      assert :ok = Worker.run_now(row.bulk_action_id)
      assert Map.keys(widgets(ctx.w2)) == ["moved"]
    end

    test "is refused on a selected record, which stays where it is", ctx do
      record = Ash.create!(Widget, %{name: "Selected"}, tenant: ctx.w1.id)

      {:ok, bulk_action} =
        AshBulkDurable.bulk_update([record], :update, %{name: nil}, scope: scope(ctx.user))

      assert :ok = Worker.run_now(bulk_action.id)
      [row] = rows(bulk_action)
      assert row.status == :failed

      assert_raise ArgumentError, ~r/its record stays the same/, fn ->
        AshBulkDurable.retry(bulk_action,
          scope: scope(ctx.user),
          rows: %{row.id => %{tenant: ctx.w2.id}}
        )
      end
    end

    test "with the tenant unchanged keeps what the row resolved", ctx do
      {bulk_action, [row]} =
        run!(ctx.user, :create, [
          %{
            target: %{tenant: ctx.w1.id},
            input: %{name: resolving("held"), parent_id: "nope"}
          }
        ])

      flush_resolved()

      {:ok, _retried} =
        AshBulkDurable.retry(bulk_action,
          scope: scope(ctx.user),
          rows: %{
            row.id => %{
              tenant: ctx.w1.id,
              input: %{name: resolving("held"), parent_id: nil}
            }
          }
        )

      assert :ok = Worker.run_now(bulk_action.id)

      refute_received {:resolved, _tenant, "held"}
      assert Map.keys(widgets(ctx.w1)) == ["held"]
    end
  end

  describe "all or nothing across tenants" do
    test "writes every tenant's rows together", ctx do
      rows = [
        %{target: %{tenant: ctx.w1.id}, input: %{name: "one"}},
        %{target: %{tenant: workspace_lookup("W2")}, input: %{name: "two"}}
      ]

      {bulk_action, _rows} = run!(ctx.user, :create, rows, mode: :all_or_nothing)

      assert bulk_action.status == :completed
      assert Map.keys(widgets(ctx.w1)) == ["one"]
      assert Map.keys(widgets(ctx.w2)) == ["two"]
    end

    test "a tenant lookup matching nothing stops it at that row, writing none", ctx do
      rows = [
        %{target: %{tenant: ctx.w1.id}, input: %{name: "one"}},
        %{target: %{tenant: workspace_lookup("NOPE")}, input: %{name: "lost"}},
        %{target: %{tenant: ctx.w2.id}, input: %{name: "two"}}
      ]

      {bulk_action, _rows} = run!(ctx.user, :create, rows, mode: :all_or_nothing)

      assert bulk_action.status == :failed
      assert bulk_action.result["row_index"] == 1

      assert Enum.map_join(bulk_action.error, & &1.message) =~
               ~s(no Workspace matches code = "NOPE")

      assert widgets(ctx.w1) == %{}
      assert widgets(ctx.w2) == %{}
    end

    test "one tenant's refused row rolls back every tenant's", ctx do
      rows = [
        %{target: %{tenant: ctx.w1.id}, input: %{name: "one"}},
        %{target: %{tenant: ctx.w2.id}, input: %{name: "two"}},
        # No name: refused by the action.
        %{target: %{tenant: ctx.w2.id}, input: %{}}
      ]

      {bulk_action, _rows} = run!(ctx.user, :create, rows, mode: :all_or_nothing)

      assert bulk_action.status == :failed
      assert bulk_action.result["reason"] == "atomic_chunk_rolled_back"
      assert bulk_action.result["row_index"] == 2
      assert widgets(ctx.w1) == %{}
      assert widgets(ctx.w2) == %{}
    end
  end
end
