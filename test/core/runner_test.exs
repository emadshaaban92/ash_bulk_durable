defmodule AshBulkDurable.Core.RunnerTest do
  @moduledoc """
  Unit tests for the primitives in `AshBulkDurable.Core.Runner` that the
  worker calls directly:

    * `resolve_references/3` — phase 1: what one row's input references
      resolve to.
    * `tenant/2` — the tenant a row acts in.
    * `run_row/2` — phase 2: runs the action with the row's input, its
      references replaced by what they resolved to.

  A row is built in memory with the fields the primitives read, as the
  worker hands them a stored `Row`.
  """
  use AshBulkDurable.DataCase, async: true

  alias AshBulkDurable.Core.{ManyMatchesError, NoMatchError, Runner}
  alias AshBulkDurable.Test.{LimitedBin, PagedBin, Region, Shelf}
  alias AshBulkDurable.Test.Scope

  # Uppercases what it is given.
  defmodule UpperCaseResolver do
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(raw, nil, _context), do: {:ok, String.upcase(raw)}

    @impl true
    def finish(nil), do: :ok

    # Reports the record it was written to, inside the row's transaction.
    @impl true
    def after_write(record, resolved, _context) do
      send(self(), {:written, record.id, resolved})
      :ok
    end
  end

  defmodule FailingResolver do
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_args, nil, _context), do: {:error, :resolution_failed}

    @impl true
    def finish(nil), do: :ok
  end

  defmodule AmbiguousResolver do
    @behaviour AshBulkDurable.Core.Resolver

    @impl true
    def prepare(_args, _context), do: {:ok, nil}

    @impl true
    def resolve(_args, nil, _context), do: {:error, :ambiguous}

    @impl true
    def finish(nil), do: :ok
  end

  # The chunk's resolvers, as the worker prepares them.
  @resolvers %{UpperCaseResolver => nil, FailingResolver => nil, AmbiguousResolver => nil}

  defp settings(ctx, opts \\ []) do
    %Runner.Settings{
      resource: Keyword.get(opts, :resource, Region),
      action_name: Keyword.get(opts, :action_name, :create),
      action_type: Keyword.get(opts, :action_type, :create),
      mode: :per_row,
      scope: Scope.new(actor: ctx.super_user),
      tenant: Keyword.get(opts, :tenant)
    }
  end

  defp row(input, opts \\ []) do
    %{
      input: input,
      target: Keyword.get(opts, :target),
      resolved_data: Keyword.get(opts, :resolved_data, %{}),
      resolved_tenant: Keyword.get(opts, :resolved_tenant),
      row_index: 0
    }
  end

  defp region_input do
    i = System.unique_integer([:positive])
    %{name: "Region #{i}", code: "TSTB#{i}", native_name: "منطقة #{i}"}
  end

  describe "resolve_references/3" do
    test "an input holding no reference resolves nothing", ctx do
      assert {:ok, %{}} ==
               Runner.resolve_references(settings(ctx), row(%{name: "Acme"}), @resolvers)
    end

    test "returns what each reference resolves to, keyed by input name", ctx do
      row = row(%{name: {:resolve, UpperCaseResolver, "acme"}, code: "C1"})

      # `resolved_data` keys are string input names — the canonical JSONB form.
      assert {:ok, %{"name" => "ACME"}} ==
               Runner.resolve_references(settings(ctx), row, @resolvers)
    end

    test "skips inputs already in resolved_data (resume/correction semantics)", ctx do
      row =
        row(%{name: {:resolve, UpperCaseResolver, "acme"}},
          resolved_data: %{"name" => "pre-resolved"}
        )

      assert {:ok, %{}} == Runner.resolve_references(settings(ctx), row, @resolvers)
    end

    test "returns {:error, term} when a reference can't be resolved", ctx do
      row = row(%{name: {:resolve, FailingResolver, "acme"}})

      assert {:error, :resolution_failed} =
               Runner.resolve_references(settings(ctx), row, @resolvers)
    end

    test "a lookup that matches nothing names the input, the resource and the criteria", ctx do
      missing = "nobody-#{System.unique_integer([:positive])}@example.com"
      row = row(%{inserted_by_id: {:lookup, AshBulkDurable.Test.User, :email, missing}})

      assert {:error, %{field: :inserted_by_id} = error} =
               Runner.resolve_references(settings(ctx), row, @resolvers)

      assert Exception.message(error) =~ "no User matches email = #{inspect(missing)}"
    end

    test "a lookup that matches two records names the input, the resource and the criteria",
         ctx do
      aisle = "A#{System.unique_integer([:positive])}"

      # A null in a composite identity: Postgres and Ash keep nulls distinct,
      # so both shelves hold the same place.
      for code <- ["S1", "S2"],
          do: Ash.create!(Shelf, %{code: code <> aisle, aisle: aisle}, authorize?: false)

      row = row(%{shelf_id: {:lookup, Shelf, :place, %{aisle: aisle, bay: nil}}})

      assert {:error, %ManyMatchesError{field: :shelf_id} = error} =
               Runner.resolve_references(settings(ctx), row, @resolvers)

      assert error.criteria == %{aisle: aisle, bay: nil}

      assert Exception.message(error) ==
               "more than one Shelf matches aisle = #{inspect(aisle)}, bay = nil"
    end

    test "a lookup reads past a primary read's pagination, refusing a second match", ctx do
      for resource <- [PagedBin, LimitedBin] do
        aisle = "A#{System.unique_integer([:positive])}"
        lookup = {:lookup, resource, :aisle, aisle}
        row = row(%{name: lookup})

        bin = Ash.create!(resource, %{aisle: aisle})
        bin_id = bin.id

        assert {:ok, %{"name" => ^bin_id}} =
                 Runner.resolve_references(settings(ctx), row, @resolvers)

        Ash.create!(resource, %{aisle: aisle})

        assert {:error, %ManyMatchesError{field: :name}} =
                 Runner.resolve_references(settings(ctx), row, @resolvers)
      end
    end

    test "a resolver finding more than one match fails without naming a resource", ctx do
      row = row(%{name: {:resolve, AmbiguousResolver, "acme"}})

      assert {:error, %ManyMatchesError{field: :name, resource: nil} = error} =
               Runner.resolve_references(settings(ctx), row, @resolvers)

      assert Exception.message(error) == "more than one match found"
    end
  end

  describe "tenant/2" do
    test "is the target's tenant, its resolved one, or the bulk action's", ctx do
      settings = settings(ctx, tenant: "default")
      reference = {:lookup, AshBulkDurable.Test.Organization, :code, "O1"}

      assert Runner.tenant(settings, row(%{})) == "default"
      assert Runner.tenant(settings, row(%{}, target: %{tenant: "org-1"})) == "org-1"

      assert Runner.tenant(
               settings,
               row(%{}, target: %{tenant: reference}, resolved_tenant: "org-2")
             ) == "org-2"
    end
  end

  describe "run_row/2 — :create" do
    test "returns {:ok, record} created from the row's input", ctx do
      input = region_input()

      assert {:ok, %Region{} = region} = Runner.run_row(settings(ctx), row(input))
      assert region.name == input.name
      assert region.code == input.code
      assert region.native_name == input.native_name
    end

    test "returns {:error, _} for an invalid changeset (missing required field)", ctx do
      # Missing native_name — Region requires it.
      input = Map.delete(region_input(), :native_name)

      assert {:error, _} = Runner.run_row(settings(ctx), row(input))
    end
  end

  describe "run_row/2 — references" do
    test "sends a reference's resolved value and hands the resolver the written record", ctx do
      i = System.unique_integer([:positive])

      input = %{
        region_input()
        | name: {:resolve, UpperCaseResolver, "raw"}
      }

      row = row(input, resolved_data: %{"name" => "Resolved #{i}"})

      assert {:ok, region} = Runner.run_row(settings(ctx), row)
      assert region.name == "Resolved #{i}"
      resolved = "Resolved #{i}"
      id = region.id
      assert_received {:written, ^id, ^resolved}
    end
  end

  describe "run_row/2 — :update and :destroy" do
    setup ctx do
      i = System.unique_integer([:positive])

      region =
        Ash.create!(Region, %{name: "Original #{i}", code: "ORIG#{i}", native_name: "أصلي #{i}"},
          actor: ctx.super_user
        )

      %{region: region, i: i}
    end

    test "updates the record its target looks up", %{region: region, i: i} = ctx do
      settings = settings(ctx, action_name: :update, action_type: :update)
      row = row(%{name: "Updated #{i}"}, target: %{lookup: %{code: region.code}})

      assert {:ok, %Region{} = updated} = Runner.run_row(settings, row)
      assert updated.name == "Updated #{i}"
      assert updated.id == region.id
    end

    test "a lookup matching no record fails the row naming what it looked up", ctx do
      settings = settings(ctx, action_name: :update, action_type: :update)
      row = row(%{name: "x"}, target: %{lookup: %{code: "NO-SUCH-#{ctx.i}"}})

      assert {:error, %NoMatchError{field: nil} = error} = Runner.run_row(settings, row)
      assert error.resource == Region
      assert error.criteria == %{code: "NO-SUCH-#{ctx.i}"}
    end

    # The clause narrowed the read, so the row names it: an A1 exists, only
    # not under this shelf.
    test "a lookup matching no record keeps the clause through a relationship it read by",
         ctx do
      aisle = "A#{System.unique_integer([:positive])}"

      [here, there] =
        for code <- ["S", "T"], do: Ash.create!(Shelf, %{code: code <> aisle}, authorize?: false)

      Ash.create!(PagedBin, %{aisle: aisle, shelf_id: there.id})
      lookup = %{aisle: aisle, shelf: %{code: here.code}}
      settings = settings(ctx, resource: PagedBin, action_name: :update, action_type: :update)

      assert {:error, %NoMatchError{field: nil, criteria: ^lookup} = error} =
               Runner.run_row(settings, row(%{aisle: "moved"}, target: %{lookup: lookup}))

      assert Exception.message(error) ==
               "no Paged Bin matches aisle = #{inspect(aisle)}, shelf.code = #{inspect(here.code)}"
    end

    test "a row with no lookup names the resource it looked in", ctx do
      settings = settings(ctx, action_name: :update, action_type: :update)

      assert {:error, %NoMatchError{field: nil, criteria: criteria} = error} =
               Runner.run_row(settings, row(%{name: "x"}))

      assert criteria == %{}
      assert Exception.message(error) == "the row names no Region"
    end

    # A key that isn't unique, read through a primary read that pages: the
    # row acts on neither match.
    test "a lookup matching two records fails the row naming what it looked up", ctx do
      for resource <- [PagedBin, LimitedBin] do
        aisle = "A#{System.unique_integer([:positive])}"
        settings = settings(ctx, resource: resource, action_name: :update, action_type: :update)
        row = row(%{aisle: aisle <> " moved"}, target: %{lookup: %{aisle: aisle}})

        first = Ash.create!(resource, %{aisle: aisle})
        second = Ash.create!(resource, %{aisle: aisle})

        assert {:error, %ManyMatchesError{field: nil} = error} = Runner.run_row(settings, row)
        assert error.resource == resource
        assert error.criteria == %{aisle: aisle}

        assert Enum.map([first, second], &Ash.reload!(&1).aisle) == [aisle, aisle]
      end
    end

    test "names a clause however many relationships deep it goes" do
      error = %ManyMatchesError{
        resource: PagedBin,
        criteria: %{shelf: %{owner: %{email: "a@example.com"}, code: "S1"}, aisle: "A1"}
      }

      assert Exception.message(error) ==
               ~s(more than one Paged Bin matches aisle = "A1", shelf.code = "S1", ) <>
                 ~s(shelf.owner.email = "a@example.com")
    end

    test "a destroy whose lookup matches two records fails the row, destroying neither", ctx do
      for resource <- [PagedBin, LimitedBin] do
        aisle = "A#{System.unique_integer([:positive])}"
        settings = settings(ctx, resource: resource, action_name: :destroy, action_type: :destroy)
        row = row(%{}, target: %{lookup: %{aisle: aisle}})

        bins = for _n <- 1..2, do: Ash.create!(resource, %{aisle: aisle})

        assert {:error, %ManyMatchesError{field: nil, criteria: %{aisle: ^aisle}}} =
                 Runner.run_row(settings, row)

        assert Enum.map(bins, &Ash.reload!(&1).id) == Enum.map(bins, & &1.id)
      end
    end

    test "a lookup matching two records keeps the clause through a relationship it read by",
         ctx do
      aisle = "A#{System.unique_integer([:positive])}"
      shelf = Ash.create!(Shelf, %{code: "S" <> aisle}, authorize?: false)
      for _n <- 1..2, do: Ash.create!(PagedBin, %{aisle: aisle, shelf_id: shelf.id})
      lookup = %{aisle: aisle, shelf: %{code: shelf.code}}
      settings = settings(ctx, resource: PagedBin, action_name: :update, action_type: :update)

      assert {:error, %ManyMatchesError{criteria: ^lookup} = error} =
               Runner.run_row(settings, row(%{aisle: "moved"}, target: %{lookup: lookup}))

      assert Exception.message(error) ==
               "more than one Paged Bin matches aisle = #{inspect(aisle)}, " <>
                 "shelf.code = #{inspect(shelf.code)}"
    end

    test "destroys the record its target looks up, returning it",
         %{region: region} = ctx do
      settings = settings(ctx, action_name: :destroy, action_type: :destroy)
      row = row(%{}, target: %{lookup: %{code: region.code}})

      assert {:ok, %Region{id: id}} = Runner.run_row(settings, row)
      assert id == region.id
      assert {:error, _} = Ash.get(Region, id, actor: ctx.super_user)
    end
  end
end
