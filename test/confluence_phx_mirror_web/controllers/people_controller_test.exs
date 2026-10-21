defmodule ConfluencePhxMirrorWeb.PeopleControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Mirror.URLs

  setup do
    demo_snapshot!()
    :ok
  end

  defp author(name), do: Enum.find(Mirror.authors(), &(&1.name == name))

  describe "the people directory" do
    test "lists the authors seen on mirrored content", %{conn: conn} do
      html = conn |> get(~p"/people") |> html_response(200)

      assert html =~ "Jane Doe"
      assert html =~ "Priya Nair"
      assert html =~ "Sam Rivera"
      assert html =~ URLs.person_path(author("Jane Doe").account_id)
    end
  end

  describe "one person" do
    test "lists the content they authored", %{conn: conn} do
      jane = author("Jane Doe")

      html = conn |> get(URLs.person_path(jane.account_id)) |> html_response(200)

      assert html =~ "Jane Doe"
      assert html =~ "Architecture Overview"
      refute html =~ "Release 2.0"
    end

    test "an unknown account is a 404", %{conn: conn} do
      body = conn |> get(~p"/people/nobody") |> html_response(404)
      assert body =~ "Nobody with that account"
    end
  end
end
