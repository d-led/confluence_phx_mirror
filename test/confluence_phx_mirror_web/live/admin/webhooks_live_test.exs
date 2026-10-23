defmodule ConfluencePhxMirrorWeb.Live.AdminWebhooksLiveTest do
  @moduledoc """
  The page that receives webhook deliveries has to say, loudly, when it trusts
  whoever can reach it — and close the intake without a restart once the
  administrator has decided.
  """

  use ConfluencePhxMirrorWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ConfluencePhxMirror.Settings

  setup do
    previous = Application.get_env(:confluence_phx_mirror, :webhooks)

    Application.put_env(:confluence_phx_mirror, :webhooks,
      secret: "the-secret",
      require_signature: false
    )

    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :webhooks, previous) end)
    :ok
  end

  test "an unprotected intake is announced on the page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/webhooks")

    assert has_element?(view, "#webhook-unsigned-warning")
    assert has_element?(view, "#webhook-require-signatures")
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
    assert Settings.webhook_rate_limit() == nil
  end
end
