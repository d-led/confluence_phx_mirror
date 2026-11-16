defmodule ConfluencePhxMirrorWeb.CoreComponentsTest do
  @moduledoc """
  The one thing every admin form depends on and no screen test could show: a
  field the changeset refused says what is wrong, under the field itself.

  Nothing in the suite renders an invalid form — the screens are tested with
  valid submissions — so the message pipeline (the changeset's error, the
  backend's translation, the `<.error>` mark) had no test at all. Rendered here
  on a component of its own rather than through a screen, because the question
  is the component's, not a page's.
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [to_form: 2]
  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirrorWeb.CoreComponents

  test "a field the changeset refused carries its message" do
    html = render_component(&CoreComponents.input/1, type: "text", field: field())

    assert html =~ "is not a valid e-mail address"
    assert html =~ "text-error"
  end

  # What a screen holds after a refused submission: a changeset whose action is
  # set, which is what `to_form/2` reads as "this was submitted": without the
  # action the form is a blank one waiting for input, and carries no errors.
  defp field do
    {:error, changeset} =
      %User{}
      |> User.changeset(%{"email" => "not-an-address"})
      |> Ecto.Changeset.apply_action(:insert)

    form = to_form(changeset, as: :user)

    form[:email]
  end
end
