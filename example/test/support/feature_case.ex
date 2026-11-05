defmodule ExampleWeb.FeatureCase do
  @moduledoc "A page driven as its user drives it, through `PhoenixTest`."
  use ExUnit.CaseTemplate

  alias Phoenix.LiveViewTest

  using do
    quote do
      use ExampleWeb, :verified_routes

      import ExampleWeb.FeatureCase
      import ExampleWeb.TestHelpers
      import PhoenixTest
    end
  end

  setup tags do
    ExampleWeb.TestHelpers.common_setup_with_conn(tags)
  end

  @doc "Picks `opts[:option]` in the select `label` names, sending the change the browser would."
  def select_change(session, label, opts \\ []) do
    session = PhoenixTest.assert_has(session, "label", text: label)
    session = PhoenixTest.assert_has(session, "option", text: opts[:option])

    # A `within/3` applies here too: `element/3` queries the whole view, and two
    # cards can share a label.
    scope =
      case session.within do
        :none -> ""
        selector when is_binary(selector) -> selector <> " "
      end

    PhoenixTest.unwrap(session, fn view ->
      label_for =
        view
        |> LiveViewTest.element("#{scope}label", Regex.compile!("^\\s*#{label}\\s*$"))
        |> attribute("for")

      value =
        view
        |> LiveViewTest.element(
          "#{scope}select[name=#{label_for}]>option",
          Regex.compile!("^\\s*#{opts[:option]}\\s*$")
        )
        |> attribute("value")

      view
      |> LiveViewTest.element("#{scope}select[name=#{label_for}]")
      |> LiveViewTest.render_change(%{"_target" => [label_for], label_for => value})
    end)
  end

  defp attribute(element, name) do
    element
    |> LiveViewTest.render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute(name)
    |> List.first()
  end
end
