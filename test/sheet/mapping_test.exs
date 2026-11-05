defmodule AshBulkDurable.Sheet.MappingTest do
  @moduledoc """
  `AshBulkDurable.Sheet.Mapping.rows/3` turns sheet rows into the target +
  input rows the core runs, bracketing them with each handler's
  `prepare/2` and `finish/2`, and the mapping survives being kept on the
  bulk action.

  `async: false`: the handler tests register their handlers in the global
  `:ash_bulk_durable` config.
  """
  use AshBulkDurable.DataCase, async: false

  require Ash.Query

  alias AshBulkDurable.Sheet.{Field, Mapping, PrepareContext}
  alias AshBulkDurable.Test.Booking
  alias AshBulkDurable.Test.Scope
  alias AshBulkDurable.Test.Branch
  alias AshBulkDurable.Test.{Region, User}
  alias AshBulkDurable.Test.RoleTestHelpers

  # A cell it can't make a value of: the row is stored failed with its error.
  defmodule RefusingHandler do
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%Field{resource: Region, field: %{name: :native_name}}), do: true
    def handles?(_field), do: false

    @impl true
    def input_value(%Field{field: field}, _raw, _ctx),
      do:
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(field: field.name, message: "not a name")}
  end

  # Refuses a phone that is no number, an optional input: a row run without it
  # would succeed having silently lost the cell.
  defmodule PhoneHandler do
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%Field{resource: User, field: %{name: :phone}}), do: true
    def handles?(_field), do: false

    @impl true
    def input_value(_field, "+" <> _digits = phone, _ctx), do: {:ok, phone}

    def input_value(%Field{field: field}, _raw, _ctx),
      do:
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(field: field.name, message: "not a phone")}
  end

  # Records its lifecycle, and refuses the sheet when asked to.
  defmodule TrackingHandler do
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%Field{resource: Region, field: %{name: :native_name}}), do: true
    def handles?(_field), do: false

    @impl true
    def prepare(_field, _ctx) do
      send(self(), :prepared)
      if Process.get(:refuse_prepare), do: {:error, :refused}, else: {:ok, :state}
    end

    @impl true
    def finish(_field, state) do
      send(self(), {:finished, state})
      :ok
    end

    @impl true
    def input_value(_field, raw, %{state: :state}), do: {:ok, "tracked #{raw}"}
  end

  # Tells the test which tenant it was handed, preparing and for each row.
  defmodule TenantHandler do
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%Field{resource: Region, field: %{name: :native_name}}), do: true
    def handles?(_field), do: false

    @impl true
    def prepare(_field, %{tenant: tenant}) do
      send(self(), {:prepared_in, tenant})
      {:ok, :state}
    end

    @impl true
    def input_value(_field, raw, %{tenant: tenant}) do
      send(self(), {:row_in, tenant})
      {:ok, raw}
    end
  end

  defmodule LastFieldRefusesHandler do
    use AshBulkDurable.Sheet.FieldHandler

    @impl true
    def handles?(%Field{resource: Region, field: %{name: name}}),
      do: name in [:code, :native_name]

    def handles?(_field), do: false

    @impl true
    def prepare(%Field{field: %{name: :native_name}}, _ctx), do: {:error, :refused}
    def prepare(_field, _ctx), do: {:ok, :state}

    @impl true
    def finish(_field, state) do
      send(self(), {:finished, state})
      :ok
    end

    @impl true
    def input_value(_field, raw, _ctx), do: {:ok, raw}
  end

  defp put_handlers(handlers) do
    AshBulkDurable.StorageHelpers.put_config(:field_handlers, handlers)
  end

  defp mapping(action, opts \\ []) do
    %Mapping{
      resource: Region,
      action: Ash.Resource.Info.action(Region, action),
      identity: opts[:identity] && Ash.Resource.Info.identity(Region, opts[:identity]),
      columns:
        Keyword.get(opts, :columns, %{name: "Name", native_name: "NativeName", code: "Code"}),
      rel_identities: Keyword.get(opts, :rel_identities, %{})
    }
  end

  defp scope(ctx), do: Scope.new(actor: ctx.super_user)

  defp context(ctx), do: %PrepareContext{scope: scope(ctx)}

  describe "rows/3" do
    test "a create's row is the input its mapped columns give, the sheet row its metadata",
         ctx do
      sheet_row = %{"Name" => "Alpha", "NativeName" => "", "Code" => "A1", "Unmapped" => "x"}

      assert {:ok, [row]} = Mapping.rows(mapping(:create), [sheet_row], context(ctx))

      # An empty cell sends "" (Ash casts it to nil); an unmapped column sends nothing.
      assert row == %{
               target: nil,
               input: %{name: "Alpha", native_name: "", code: "A1"},
               metadata: sheet_row,
               error: nil
             }
    end

    test "a column the mapping leaves out sends nothing", ctx do
      assert {:ok, [%{input: input}]} =
               Mapping.rows(
                 mapping(:create, columns: %{name: "Name"}),
                 [%{"Name" => "Alpha", "Code" => "A1"}],
                 context(ctx)
               )

      assert input == %{name: "Alpha"}
    end

    test "an update's identity columns look its record up", ctx do
      assert {:ok, [row]} =
               Mapping.rows(
                 mapping(:update, identity: :code),
                 [%{"Name" => "Beta", "NativeName" => "ب", "Code" => "B1"}],
                 context(ctx)
               )

      assert row.target == %{lookup: %{code: "B1"}}
      assert row.input.name == "Beta"
    end

    test "a belongs_to cell is a lookup sent as its source attribute", ctx do
      mapping = %Mapping{
        resource: Branch,
        action: Ash.Resource.Info.action(Branch, :create),
        columns: %{name: "Name", region: "Region"},
        rel_identities: %{region: :code}
      }

      assert {:ok, [%{input: input}]} =
               Mapping.rows(mapping, [%{"Name" => "Branch", "Region" => "G1"}], context(ctx))

      assert input == %{name: "Branch", region_id: {:lookup, Region, :code, "G1"}}
    end

    test "a cell a handler refuses stores the row with its error", ctx do
      put_handlers([RefusingHandler])

      assert {:ok, [%{error: [%{field: :native_name, message: "not a name"}]} = row]} =
               Mapping.rows(
                 mapping(:create),
                 [%{"Name" => "x", "NativeName" => "y"}],
                 context(ctx)
               )

      refute Map.has_key?(row.input, :native_name)
    end

    test "prepares each handler once, threads its state, and finishes it", ctx do
      put_handlers([TrackingHandler])
      rows = [%{"NativeName" => "a"}, %{"NativeName" => "b"}]

      assert {:ok, [%{input: %{native_name: "tracked a"}}, %{input: %{native_name: "tracked b"}}]} =
               Mapping.rows(mapping(:create), rows, context(ctx))

      assert_received :prepared
      refute_received :prepared
      assert_received {:finished, :state}
    end

    test "a handler refusing to prepare refuses the sheet", ctx do
      put_handlers([TrackingHandler])
      Process.put(:refuse_prepare, true)

      assert {:error, :refused} = Mapping.rows(mapping(:create), [%{}], context(ctx))
    end

    test "a handler refusing to prepare finishes the ones prepared before it", ctx do
      put_handlers([LastFieldRefusesHandler])

      assert {:error, :refused} = Mapping.rows(mapping(:create), [%{}], context(ctx))

      assert_received {:finished, :state}
    end
  end

  describe "a corrected errors sheet" do
    test "a handler refusing to prepare refuses the corrections, reopening nothing", ctx do
      put_handlers([TrackingHandler])
      scope = scope(ctx)

      {:ok, bulk_action} =
        AshBulkDurable.Sheet.stage(
          [%{"Name" => "x", "NativeName" => "y", "Code" => "C"}],
          mapping(:create),
          scope: scope
        )

      [row] =
        AshBulkDurable.Test.Row
        |> Ash.Query.filter(bulk_action_id == ^bulk_action.id)
        |> Ash.read!(authorize?: false)

      Ash.update!(row, %{error: "boom"}, action: :mark_failed, authorize?: false)

      bulk_action =
        Ash.update!(bulk_action, %{result: :completed_with_errors},
          action: :mark_finished,
          authorize?: false
        )

      Process.put(:refuse_prepare, true)
      corrected = %AshBulkDurable.Sheet{rows: [%{"row_id" => row.id, "name" => "fixed"}]}

      assert {:error, :refused} = AshBulkDurable.retry(bulk_action, corrected, scope: scope)

      assert Ash.get!(AshBulkDurable.Test.Row, row.id, authorize?: false).status == :failed
    end

    test "a row a handler refused never runs as it is, only once corrected", ctx do
      put_handlers([RefusingHandler])
      scope = scope(ctx)
      tag = "R#{System.unique_integer([:positive])}"

      {:ok, bulk_action} =
        AshBulkDurable.Sheet.stage(
          [%{"Name" => "Name #{tag}", "NativeName" => "unreadable", "Code" => tag}],
          mapping(:create),
          scope: scope
        )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
      bulk_action = Ash.reload!(bulk_action, authorize?: false)
      assert bulk_action.status == :completed_with_errors

      # Its input lacks the cell the handler refused, so running it would
      # write a record without it.
      assert {:ok, bulk_action} = AshBulkDurable.retry(bulk_action, scope: scope)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)

      bulk_action = Ash.reload!(bulk_action, authorize?: false)
      assert bulk_action.status == :completed_with_errors
      assert bulk_action.rows_done == 0

      assert [%{status: :failed, refused: true, error: [%{message: message}]} = row] =
               AshBulkDurable.Core.open_rows(bulk_action)

      assert message =~ "not a name"

      Application.delete_env(:ash_bulk_durable, :field_handlers)

      corrected = %AshBulkDurable.Sheet{
        rows: [%{"row_id" => row.id, "native_name" => "اسم #{tag}"}]
      }

      assert {:ok, _retried} = AshBulkDurable.retry(bulk_action, corrected, scope: scope)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)

      assert Ash.reload!(bulk_action, authorize?: false).status == :completed
      assert Ash.get!(Region, %{code: tag}, authorize?: false).native_name == "اسم #{tag}"
    end
  end

  describe "the tenant a handler is handed" do
    setup ctx do
      put_handlers([TenantHandler])
      tag = "T#{System.unique_integer([:positive])}"

      %{
        first: RoleTestHelpers.create_organization(ctx.super_user),
        second: RoleTestHelpers.create_organization(ctx.super_user),
        row: %{"Name" => "Name #{tag}", "NativeName" => "اسم #{tag}", "Code" => tag}
      }
    end

    defp acting_in(user, organization) do
      user = Ash.reload!(user, authorize?: false)
      Scope.new(actor: User.change_tenant!(user, organization.id, actor: user, authorize?: false))
    end

    defp assert_handed(tenant) do
      assert_received {:prepared_in, ^tenant}
      assert_received {:row_in, ^tenant}
      refute_received {:prepared_in, _tenant}
      refute_received {:row_in, _tenant}
    end

    test "is the one a sheet is staged for, the scope's unless :tenant names another", ctx do
      scope = acting_in(ctx.super_user, ctx.first)

      {:ok, staged} = AshBulkDurable.Sheet.stage([ctx.row], mapping(:create), scope: scope)
      assert staged.tenant == ctx.first.id
      assert_handed(ctx.first.id)
      Ash.update!(staged, %{result: :cancelled}, action: :mark_finished, authorize?: false)

      {:ok, named} =
        AshBulkDurable.Sheet.stage([ctx.row], mapping(:create),
          scope: scope,
          tenant: ctx.second.id
        )

      assert named.tenant == ctx.second.id
      assert_handed(ctx.second.id)
      Ash.update!(named, %{result: :cancelled}, action: :mark_finished, authorize?: false)

      {:ok, none} =
        AshBulkDurable.Sheet.stage([ctx.row], mapping(:create), scope: scope, tenant: nil)

      assert none.tenant == nil
      assert_handed(nil)
    end

    test "correcting a sheet, is the bulk action's, wherever its owner acts now", ctx do
      Ash.create!(
        Region,
        %{code: ctx.row["Code"], name: "Other", native_name: "أخرى #{ctx.row["Code"]}"},
        actor: ctx.super_user
      )

      scope = acting_in(ctx.super_user, ctx.first)
      {:ok, bulk_action} = AshBulkDurable.Sheet.stage([ctx.row], mapping(:create), scope: scope)
      assert_handed(ctx.first.id)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
      bulk_action = Ash.reload!(bulk_action, authorize?: false)
      assert bulk_action.status == :completed_with_errors

      moved = acting_in(ctx.super_user, ctx.second)
      sheet = AshBulkDurable.errors_sheet(bulk_action)
      code = "T#{System.unique_integer([:positive])}"

      corrected = %{
        sheet
        | rows:
            Enum.map(
              sheet.rows,
              &Map.merge(&1, %{"code" => code, "native_name" => "اسم #{code}"})
            )
      }

      {:ok, _retried} = AshBulkDurable.retry(bulk_action, corrected, scope: moved)
      assert_handed(ctx.first.id)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
      assert Ash.reload!(bulk_action, authorize?: false).status == :completed
      assert Ash.get!(Region, %{code: code}, authorize?: false).native_name == "اسم #{code}"
    end
  end

  describe "a cell a handler refused" do
    setup ctx do
      put_handlers([PhoneHandler])
      %{scope: scope(ctx), tag: "P#{System.unique_integer([:positive])}"}
    end

    defp run_retry!(bulk_action, sheet, scope) do
      assert {:ok, _retried} = AshBulkDurable.retry(bulk_action, sheet, scope: scope)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
      Ash.reload!(bulk_action, authorize?: false)
    end

    defp edited(sheet, cells), do: %{sheet | rows: Enum.map(sheet.rows, &Map.merge(&1, cells))}

    defp phone_mapping(action, opts \\ []) do
      %Mapping{
        resource: User,
        action: Ash.Resource.Info.action(User, action),
        identity: opts[:identity] && Ash.Resource.Info.identity(User, opts[:identity]),
        columns: %{name: "Full name", email: "Mail", phone: "Phone"}
      }
    end

    test "stays on the sheet and stays refused until the cell itself is put right", ctx do
      %{scope: scope, tag: tag} = ctx
      email = "#{tag}@example.test"

      {:ok, bulk_action} =
        AshBulkDurable.Sheet.stage(
          [%{"Full name" => "Wrong", "Mail" => email, "Phone" => "ten digits"}],
          phone_mapping(:create),
          scope: scope
        )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
      bulk_action = Ash.reload!(bulk_action, authorize?: false)

      sheet = AshBulkDurable.errors_sheet(bulk_action)
      assert [%{"phone" => "ten digits", "name" => "Wrong"}] = sheet.rows

      # Correcting another cell keeps that correction but runs nothing: the
      # row has no phone to run with yet.
      bulk_action = run_retry!(bulk_action, edited(sheet, %{"name" => "Right"}), scope)
      assert bulk_action.status == :completed_with_errors
      assert bulk_action.rows_done == 0

      assert Ash.read!(User, actor: ctx.super_user)
             |> Enum.filter(&(to_string(&1.email) == email)) == []

      sheet = AshBulkDurable.errors_sheet(bulk_action)

      assert [%{"phone" => "ten digits", "name" => "Right", "last_error" => last_error}] =
               sheet.rows

      assert last_error =~ "not a phone"

      # A cell refused again is the one the next sheet shows.
      bulk_action = run_retry!(bulk_action, edited(sheet, %{"phone" => "still none"}), scope)
      assert bulk_action.status == :completed_with_errors
      sheet = AshBulkDurable.errors_sheet(bulk_action)
      assert [%{"phone" => "still none", "name" => "Right"}] = sheet.rows

      bulk_action = run_retry!(bulk_action, edited(sheet, %{"phone" => "+20100"}), scope)
      assert bulk_action.status == :completed

      assert [%{name: "Right", phone: "+20100"}] =
               Enum.filter(
                 Ash.read!(User, actor: ctx.super_user),
                 &(to_string(&1.email) == email)
               )
    end

    # A row failing on a taken email, its phone never refused until `typed`
    # is corrected in: the next sheet shows what was typed, and an untouched
    # upload runs nothing rather than the row as it was.
    defp assert_refused_correction_kept(bulk_action, typed, ctx) do
      %{scope: scope, tag: tag} = ctx
      assert bulk_action.status == :completed_with_errors
      assert [%{refused: false}] = AshBulkDurable.Core.open_rows(bulk_action)

      sheet = AshBulkDurable.errors_sheet(bulk_action)
      bulk_action = run_retry!(bulk_action, edited(sheet, %{"phone" => typed}), scope)
      assert bulk_action.status == :completed_with_errors

      sheet = AshBulkDurable.errors_sheet(bulk_action)
      assert [%{"phone" => ^typed, "last_error" => last_error}] = sheet.rows
      assert last_error =~ "not a phone"

      email = "#{tag}-free@example.test"
      bulk_action = run_retry!(bulk_action, edited(sheet, %{"email" => email}), scope)
      assert bulk_action.status == :completed_with_errors
      assert bulk_action.rows_done == 0
      assert users_with(email, ctx) == []

      sheet = AshBulkDurable.errors_sheet(bulk_action)
      assert [%{"phone" => ^typed, "email" => ^email}] = sheet.rows

      bulk_action = run_retry!(bulk_action, edited(sheet, %{"phone" => "+20100"}), scope)
      assert bulk_action.status == :completed
      assert [%{phone: "+20100"}] = users_with(email, ctx)
    end

    defp users_with(email, ctx) do
      Enum.filter(Ash.read!(User, actor: ctx.super_user), &(to_string(&1.email) == email))
    end

    defp taken_email(ctx) do
      email = "#{ctx.tag}@example.test"
      Ash.create!(User, %{name: ctx.tag, email: email}, actor: ctx.super_user)
      email
    end

    test "only once corrected keeps what was typed, not what the row ran with", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.Sheet.stage(
          [%{"Full name" => ctx.tag, "Mail" => taken_email(ctx), "Phone" => "+2022"}],
          phone_mapping(:create),
          scope: ctx.scope
        )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)

      bulk_action
      |> Ash.reload!(authorize?: false)
      |> assert_refused_correction_kept("typed-wrong", ctx)
    end

    test "in a column the source sheet never mapped keeps what was typed", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.Sheet.stage(
          [%{"Full name" => ctx.tag, "Mail" => taken_email(ctx)}],
          %{phone_mapping(:create) | columns: %{name: "Full name", email: "Mail"}},
          scope: ctx.scope
        )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)

      bulk_action
      |> Ash.reload!(authorize?: false)
      |> assert_refused_correction_kept("typed-wrong", ctx)
    end

    test "of a bulk action no sheet started keeps what was typed", ctx do
      {:ok, bulk_action} =
        AshBulkDurable.bulk_create(
          [%{name: ctx.tag, email: taken_email(ctx), phone: "+2022"}],
          User,
          :create,
          scope: ctx.scope
        )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)

      bulk_action
      |> Ash.reload!(authorize?: false)
      |> assert_refused_correction_kept("typed-wrong", ctx)
    end

    test "a corrected lookup alone does not reopen the row without it", ctx do
      %{scope: scope, tag: tag, super_user: super_user} = ctx

      [first, second] =
        for n <- 1..2 do
          Ash.create!(User, %{name: "#{tag} #{n}", email: "#{tag}#{n}@example.test"},
            actor: super_user
          )
        end

      {:ok, bulk_action} =
        AshBulkDurable.Sheet.stage(
          [
            %{"Full name" => "Renamed", "Mail" => to_string(first.email), "Phone" => "ten digits"}
          ],
          phone_mapping(:update, identity: :email),
          scope: scope
        )

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :bulk_actions)
      bulk_action = Ash.reload!(bulk_action, authorize?: false)
      sheet = AshBulkDurable.errors_sheet(bulk_action)

      bulk_action =
        run_retry!(bulk_action, edited(sheet, %{"email" => to_string(second.email)}), scope)

      assert bulk_action.status == :completed_with_errors
      assert Ash.reload!(second, actor: super_user).name == second.name
    end
  end

  describe "what a row finds its record by" do
    test "the primary key, and no partial identity" do
      assert [:primary_key] == Booking |> Mapping.lookup_identities() |> Enum.map(& &1.name)
      assert %{keys: [:id]} = Mapping.lookup_identity(Booking, :primary_key)
      assert is_nil(Mapping.lookup_identity(Booking, :order))
      assert is_nil(Mapping.lookup_identity(Booking, :active_on_asset))
    end

    test "a sheet can't be staged on a partial identity" do
      mapping = %Mapping{
        resource: Booking,
        action: Ash.Resource.Info.action(Booking, :refresh),
        identity: Ash.Resource.Info.identity(Booking, :order),
        columns: %{order_id: "order"}
      }

      assert_raise ArgumentError, ~r/partial identity/, fn -> Mapping.identified!(mapping) end
    end
  end

  describe "kept on the bulk action" do
    test "from_bulk_action/1 reads back what to_metadata/1 kept", ctx do
      mapping = %{
        mapping(:update,
          identity: :code,
          columns: %{code: "Code", inserted_by: "By"},
          rel_identities: %{inserted_by: :email}
        )
        | tenant_mapping: %{rel_name: :inserted_by, identity: :email, csv_col: "By"}
      }

      bulk_action =
        Ash.create!(
          AshBulkDurable.Test.BulkAction,
          %{
            user_id: ctx.super_user.id,
            resource_name: "AshBulkDurable.Test.Region",
            action_name: :update,
            action_type: :update,
            metadata: Mapping.to_metadata(mapping),
            total_rows: 0,
            mode: :per_row,
            chunk_size: 50,
            rows: []
          },
          authorize?: false
        )

      read = Ash.get!(AshBulkDurable.Test.BulkAction, bulk_action.id, authorize?: false)

      assert Mapping.from_bulk_action(read) == mapping

      naming = %{
        mapping
        | tenant_mapping: %{resource: Region, identity: :code, csv_col: "Where"}
      }

      kept = naming |> Mapping.to_metadata() |> Jason.encode!() |> Jason.decode!()
      assert Mapping.from_bulk_action(%{read | metadata: kept}) == naming
    end
  end
end
