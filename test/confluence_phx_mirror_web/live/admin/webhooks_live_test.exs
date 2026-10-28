defmodule ConfluencePhxMirrorWeb.Live.AdminWebhooksLiveTest do
  @moduledoc """
  The page that receives webhook deliveries has to say, loudly, when it trusts
  whoever can reach it — and close the intake without a restart once the
  administrator has decided.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Repo
  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirror.TestConfig
  alias ConfluencePhxMirror.Webhooks
  alias ConfluencePhxMirror.Webhooks.Delivery

  setup %{conn: conn} do
    TestConfig.put(:webhooks, secret: "the-secret", require_signature: false)

    {:ok, conn: log_in_admin(conn)}
  end

  test "an unprotected intake is announced on the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    assert has_element?(view, "#webhook-unsigned-warning")
    assert has_element?(view, "#webhook-require-signatures")
  end

  test "deliveries page through instead of stopping at the newest handful", %{conn: conn} do
    for index <- 1..26 do
      %Delivery{}
      |> Delivery.changeset(%{
        event_type: "page_updated",
        payload: %{"page" => index},
        received_at:
          DateTime.utc_now() |> DateTime.add(-index, :second) |> DateTime.truncate(:second)
      })
      |> Repo.insert!()
    end

    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    assert view |> element("#deliveries-pager") |> render() =~ "page 1 of 2 · 26 in total"
    assert has_element?(view, ~s(#deliveries-pager a[href="/admin/webhooks?page=2"]))

    {:ok, second, _html} = live(conn, ~p"/admin/webhooks?page=2")

    assert second |> element("#deliveries-pager") |> render() =~ "page 2 of 2"
  end

  test "the administrator closes it without a restart, and can hand it back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    view |> element("#webhook-require-signatures") |> render_click()

    refute has_element?(view, "#webhook-unsigned-warning")
    assert Settings.webhook_require_signature()

    view |> element(~s(button[phx-click="allow_unsigned"])) |> render_click()

    assert has_element?(view, "#webhook-unsigned-warning")
    assert Settings.webhook_require_signature() == false
  end

  test "the intake cap can be moved by an administrator", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    view |> form("#webhook-intake-form", %{"limit" => "7"}) |> render_submit()

    assert Settings.webhook_rate_limit() == 7
    assert has_element?(view, "#webhook-controls", "7 deliveries a minute")
  end

  test "a cap that is not a number is refused with a readable message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    html = view |> form("#webhook-intake-form", %{"limit" => "0"}) |> render_submit()

    assert html =~ "The cap must be a whole number above zero."
    assert Settings.stored("webhook.rate_limit") == nil
  end

  test "an administrator switches the intake off and the page says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    view |> element("#webhook-switch-off") |> render_click()

    assert has_element?(view, "#webhook-intake-off")
    assert has_element?(view, "#webhook-intake-state", "off (answered as unrouted)")
    assert Settings.webhook_enabled?() == false
  end

  test "a delivery is refused once the intake is off, not merely ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    view |> element("#webhook-switch-off") |> render_click()

    assert {:error, :disabled} = Webhooks.receive(%{"event" => "page_updated"}, "{}", [])
  end

  test "the intake hands the decision back to the deployment", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    view |> element("#webhook-switch-off") |> render_click()
    view |> element(~s(button[phx-click="use_configured_intake"])) |> render_click()

    refute has_element?(view, "#webhook-intake-off")
    assert Settings.stored("webhook.enabled") == nil
    assert Webhooks.enabled?()
  end
end
