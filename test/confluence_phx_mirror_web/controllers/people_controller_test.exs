defmodule ConfluencePhxMirrorWeb.PeopleControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: true

  import ConfluencePhxMirror.Fixtures

  describe "one person" do
    test "lists the content they authored", %{conn: conn} do
      space = space_fixture()

      page_fixture(space, %{
        title: "Architecture Overview",
        author_name: "Jane Doe",
        author_account_id: "acc-jane"
      })

      page_fixture(space, %{
        title: "Release 2.0",
        type: "blogpost",
        author_name: "Sam Rivera",
        author_account_id: "acc-sam"
      })

      html = conn |> get(~p"/people/acc-jane") |> html_response(200)

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
