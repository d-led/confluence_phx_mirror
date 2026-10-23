defmodule ConfluencePhxMirrorWeb.SkinsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirrorWeb.Skins

  defmodule TestPack do
    @behaviour ConfluencePhxMirrorWeb.Skins.Pack

    @impl true
    def skins do
      [%{name: "pack-skin", label: "Pack", colors: %{primary: "#0b5fff"}}]
    end
  end

  defp with_skins(skins), do: put_config(:skins, skins)
  defp with_skin_packs(packs), do: put_config(:skin_packs, packs)
  defp with_site_skin(name), do: put_config(:site_skin, name)
  defp with_default_skin(name), do: put_config(:default_skin, name)

  defp put_config(key, value) do
    previous = Application.fetch_env(:confluence_phx_mirror, key)
    Application.put_env(:confluence_phx_mirror, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:confluence_phx_mirror, key, old)
        :error -> Application.delete_env(:confluence_phx_mirror, key)
      end
    end)
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
    test "offers the built-in skins" do
      builtins = Skins.all() |> Enum.filter(& &1.builtin?) |> Enum.map(& &1.name)

      assert builtins == ~w(system light mirror dark)
    end

    test "ships the Atlassian Cloud pack" do
      assert %{label: "Atlassian Cloud"} = Skins.get("atlassian-cloud")
    end

    test "appends site skins and reports them in the picker" do
      with_skins([@acme])

      assert Enum.any?(Skins.all(), &(&1.name == "acme" and &1.label == "Acme"))
      assert Skins.valid?("acme")
      refute Skins.valid?("no-such-skin")
    end

    test "takes skins from a pack module" do
      with_skin_packs([TestPack])

      assert Skins.valid?("pack-skin")
      assert Skins.style() =~ ~s([data-theme="pack-skin"])
    end

    test "cannot shadow a built-in skin" do
      with_skins([%{name: "dark", colors: %{primary: "#ff0000"}}])

      assert Skins.get("dark").builtin?
      refute String.contains?(Skins.style(), "#ff0000")
    end

    test "ignores entries with names that are not CSS-selector safe" do
      with_skins([%{name: "Acme Corp", colors: %{primary: "#0b5fff"}}])

      refute Skins.valid?("Acme Corp")
      refute Skins.style() =~ "Acme Corp"
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
      refute Skins.style() =~ ~s([data-theme="acme"])
    end
  end

  describe "a skin with a dark variant" do
    test "keeps one name and follows the OS preference" do
      with_skin_packs([])

      with_skins([
        %{
          name: "brand",
          colors: %{base_100: "#ffffff"},
          dark_colors: %{base_100: "#111214"}
        }
      ])

      css = Skins.style()

      assert css =~ ~s([data-theme="brand"]{color-scheme:light;--color-base-100:#ffffff})
      assert css =~ ~s|@media (prefers-color-scheme:dark){[data-theme="brand"]{color-scheme:dark|
      assert css =~ "--color-base-100:#111214"
    end

    test "shares the geometry between the variants" do
      with_skin_packs([])

      with_skins([
        %{
          name: "brand",
          colors: %{base_100: "#ffffff"},
          dark_colors: %{base_100: "#111214"},
          radius: %{box: "0.375rem"}
        }
      ])

      [_light, dark] = String.split(Skins.style(), "@media (prefers-color-scheme:dark)")

      assert dark =~ "--color-base-100:#111214}"
      refute dark =~ "--radius-box"
    end
  end

  describe "the reader's picker" do
    test "lists the selectable skins only" do
      with_site_skin(nil)
      with_skins([@acme, Map.merge(@acme, %{name: "whole", selectable: false})])

      names = Enum.map(Skins.reader_skins(), & &1.name)

      assert "acme" in names
      assert "atlassian-cloud" in names
      refute "whole" in names
      assert Skins.valid?("whole")
    end

    test "is empty when the site pins one skin for everyone" do
      with_site_skin("atlassian-cloud")

      assert Skins.reader_skins() == []
    end
  end

  describe "the default skin" do
    test "is what a reader gets before they choose one", %{conn: conn} do
      with_site_skin(nil)
      with_skins([@acme])
      with_default_skin("acme")

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(data-theme="acme")
      assert html =~ ~s(href="/theme/dark")
    end

    test "loses to the reader's own choice", %{conn: conn} do
      with_site_skin(nil)
      with_skins([@acme])
      with_default_skin("acme")

      html =
        conn
        |> Plug.Test.put_req_cookie("mirror_theme", "dark")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ ~s(data-theme="dark")
    end

    test "falls back to system when it is not a skin this site offers" do
      with_default_skin("no-such-skin")

      assert Skins.default_skin() == "system"
    end
  end

  describe "the site skin" do
    test "applies to every reader, whatever the cookie says", %{conn: conn} do
      with_skins([@acme])
      with_site_skin("acme")

      conn =
        conn
        |> Plug.Test.put_req_cookie("mirror_theme", "dark")
        |> get(~p"/")

      html = html_response(conn, 200)

      assert html =~ ~s(data-theme="acme")
      assert html =~ "--color-primary:#0b5fff"
    end

    test "removes the reader's picker", %{conn: conn} do
      with_skins([@acme])
      with_site_skin("acme")

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ ~s(href="/theme/)
    end
  end

  describe "validate!/0" do
    test "accepts skins the site offers" do
      with_site_skin("atlassian-cloud")
      with_default_skin("atlassian-cloud")

      assert :ok = Skins.validate!()
    end

    test "stops the release on a typo" do
      with_site_skin("atlasean-cloud")

      assert_raise ArgumentError, ~r/site_skin .* is not a skin this site offers/, fn ->
        Skins.validate!()
      end
    end

    test "stops the release on a misspelt default" do
      with_default_skin("atlasean-cloud")

      assert_raise ArgumentError, ~r/default_skin .* is not a skin this site offers/, fn ->
        Skins.validate!()
      end
    end

    test "is a no-op when readers choose" do
      with_site_skin(nil)
      with_default_skin(nil)

      assert :ok = Skins.validate!()
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
      with_site_skin(nil)
      with_skins([@acme])

      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="/theme/acme")
      assert html =~ ~s([data-theme="acme"])
      assert html =~ "--color-primary:#0b5fff"
    end

    test "renders no theme rule when the site declares no skins", %{conn: conn} do
      with_site_skin(nil)
      with_skins([])
      with_skin_packs([])

      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ "<style>[data-theme="
    end
  end
end
