defmodule AshBulkDurable.Sheet.Field do
  @moduledoc """
  Every callback in `AshBulkDurable.Sheet.FieldHandler` that takes a `field` parameter
  receives one of these — not a bare Ash attribute/argument/relationship.

  Bundling the Ash field with `resource` and `action` lets handlers override
  claim or behavior on a per-resource, per-action basis via pattern matching:

      def handles?(%AshBulkDurable.Sheet.Field{
        resource: MyApp.Posts.Post,
        action: %{name: :create_with_validation},
        field: %{name: :attachments}
      }), do: true

      def handles?(_), do: false
  """

  defstruct [:field, :resource, :action]

  @type t :: %__MODULE__{
          field:
            Ash.Resource.Attribute.t()
            | Ash.Resource.Actions.Argument.t()
            | Ash.Resource.Relationships.relationship(),
          resource: Ash.Resource.t(),
          action: Ash.Resource.Actions.action()
        }
end
