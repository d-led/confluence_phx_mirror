defmodule ConfluencePhxMirrorWeb.SkinsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirrorWeb.Skins

  defp with_skins(skins) do
    previous = Application.get_env(:confluence_phx_mirror, :skins)
    Application.put_env(:confluence_phx_mirror, :skins, skins)
    on_exit(fn -> Application.put_env(:confluence_phx_mirror, :skins, previous) end)
  end

  @acme %{
    name: "acme",
    label: "Acme",
    icon: "hero-building-office",
    scheme: :dark,
    colors: %{primary: "#0b5fff", base_100: "#101820"},
    radius: %{box: "0.5rem"}
  }

  describe "the registry" do
    test "always offers the built-in skins" do
      assert ["system", "light", "mirror", "dark"] ==
               Enum.map(Skins.all(), & &1.name)
    end

    test "appends site skins and reports them in the picker" do
      with_skins([@acme])

      assert Enum.any?(Skins.all(), &(&1.name == "acme" and &1.label == "Acme"))
      assert Skins.valid?("acme")
      refute Skins.valid?("no-such-skin")
    end

    test "cannot shadow a built-in skin" do
      with_skins([%{name: "dark", colors: %{primary: "#ff0000"}}])

      assert Skins.get("dark").builtin?
      refute String.contains?(Skins.style(), "#ff0000")
    end

    test "ignores entries with names that are not CSS-selector safe" do
      with_skins([%{name: "Acme Corp", colors: %{primary: "#0b5fff"}}])

      assert Skins.names() == ~w(system light mirror dark)
      assert Skins.style() == ""
    end
  end

  describe "the generated palette" do
    test "maps palette keys to daisyUI variables and keeps the colour scheme" do
      with_skins([@acme])

      css = Skins.style()

      assert css =~ ~s([data-theme="acme"])
      assert css =~ "color-scheme:dark"
      assert css =~ "--color-primary:#0b5fff"
      assert css =~ "--color-base-100:#101820"
      assert css =~ "--radius-box:0.5rem"
    end

    test "drops unknown keys and unsafe values" do
      with_skins([
        %{
          name: "acme",
          colors: %{primary: "red; } body { display: none", secondary: "#0b5fff"},
          radius: %{nonsense: "1rem"}
        }
      ])

      css = Skins.style()

      refute css =~ "display: none"
      assert css =~ "--color-secondary:#0b5fff"
      refute css =~ "--radius-nonsense"
    end

    test "omits skins that declare nothing" do
      with_skins([%{name: "acme", label: "Acme"}])

      assert Skins.valid?("acme")
      assert Skins.style() == ""
    end
  end

  describe "the theme route" do
    test "accepts a site skin and stores it in the cookie", %{conn: conn} do
      with_skins([@acme])

      conn = get(conn, ~p"/theme/acme")

      assert redirected_to(conn) == ~p"/"
      assert conn.resp_cookies["mirror_theme"].value == "acme"
    end

    test "falls back to system for unknown skins", %{conn: conn} do
      conn = get(conn, ~p"/theme/no-such-skin")

      assert conn.resp_cookies["mirror_theme"].value == "system"
    end
  end

  describe "the page" do
    test "renders a site skin in the picker and as a theme rule", %{conn: conn} do
      with_skins([@acme])

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="/theme/acme")
      assert html =~ ~s([data-theme="acme"])
      assert html =~ "--color-primary:#0b5fff"
    end

    test "renders no theme rule when the site declares no skins", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "<style>[data-theme="
    end
  end
end
