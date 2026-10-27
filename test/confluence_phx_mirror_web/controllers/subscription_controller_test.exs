defmodule ConfluencePhxMirrorWeb.SubscriptionControllerTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import ConfluencePhxMirror.Fixtures

  alias ConfluencePhxMirror.Accounts
  alias ConfluencePhxMirror.Demo
  alias ConfluencePhxMirror.Mirror
  alias ConfluencePhxMirror.Notifications

  setup %{conn: conn} do
    demo_snapshot!()
    {:ok, conn: log_in_admin(conn)}
  end

  test "a reader watches a page and comes back to it", %{conn: conn} do
    {:ok, page} = Mirror.find_page(1002)
    back = "/spaces/ENG/pages/1002/Architecture+Overview"

    conn =
      conn
      |> put_req_header("referer", back)
      |> post(~p"/subscriptions", %{target_type: "page", target_id: page.id})

    assert redirected_to(conn) == back
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "You will get an e-mail"
    assert Notifications.subscribed?(conn.assigns.current_user, "page", page.id)
  end

  test "watching a space works the same way", %{conn: conn} do
    {:ok, space} = Mirror.find_space("ENG")

    conn = post(conn, ~p"/subscriptions", %{target_type: "space", target_id: space.id})

    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "this space"
    assert Notifications.subscribed?(conn.assigns.current_user, "space", space.id)
  end

  test "an unknown target type is refused with an error flash", %{conn: conn} do
    conn = post(conn, ~p"/subscriptions", %{target_type: "attachment", target_id: 1})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Could not create the subscription"
    refute Notifications.subscribed?(conn.assigns.current_user, "attachment", 1)
  end

  test "unwatching removes the subscription", %{conn: conn} do
    {:ok, page} = Mirror.find_page(1002)
    user = Accounts.ensure_admin!()
    {:ok, _subscription} = Notifications.subscribe(user, "page", page.id)

    conn = delete(conn, ~p"/subscriptions", %{target_type: "page", target_id: page.id})

    assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Subscription removed."
    refute Notifications.subscribed?(user, "page", page.id)
  end

  test "unwatching something bogus is refused", %{conn: conn} do
    conn = delete(conn, ~p"/subscriptions", %{target_type: "nope", target_id: 1})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid subscription."
  end

  describe "watching something the reader may not open" do
    setup do
      # The suite assumes an administrator; these cases need a real reader.
      :ok
    end

    test "is refused without saying whether the page exists", %{conn: conn} do
      {:ok, page} = Mirror.find_page(Demo.restricted_page())
      reader = user_fixture()

      conn =
        conn
        |> init_test_session(%{user_id: reader.id})
        |> post(~p"/subscriptions", %{target_type: "page", target_id: page.id})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Could not create the subscription."

      refute Notifications.subscribed?(reader, "page", page.id)
    end

    test "is allowed for a page the reader may open", %{conn: conn} do
      {:ok, page} = Mirror.find_page(Demo.open_page())
      reader = user_fixture()

      conn =
        conn
        |> init_test_session(%{user_id: reader.id})
        |> post(~p"/subscriptions", %{target_type: "page", target_id: page.id})

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "You will get an e-mail"
      assert Notifications.subscribed?(reader, "page", page.id)
    end
  end
end
