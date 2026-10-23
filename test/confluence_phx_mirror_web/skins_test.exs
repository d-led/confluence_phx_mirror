defmodule ConfluencePhxMirrorWeb.SkinsTest do
  use ConfluencePhxMirrorWeb.ConnCase, async: false

  alias ConfluencePhxMirror.Settings
  alias ConfluencePhxMirrorWeb.Skins

  defmodule TestPack do
    @behaviour ConfluencePhxMirrorWeb.Skins.Pack

    @impl true
    def skins do
      [
        %{
          name: "pack-theme",
          label: "Pack",
          note: "a theme from a pack",
          colors: %{primary: "#0b5fff", base_100: "#ffffff"},
          dark_colors: %{primary: "#66aaff", base_100: "#101820"}
        }
      ]
    end
  end

  setup do
    Settings.reload()
    on_exit(fn -> Settings.reload() end)
    :ok
  end

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

  describe "themes" do
    test "ships the default and the Fresh blue pack" do
      names = Enum.map(Skins.themes(), & &1.name)

      assert "default" in names
      assert "fresh-blue" in names
    end

    test "takes a theme from a pack, light and dark together" do
      put_config(:skin_packs, [TestPack])

      assert Skins.theme?("pack-theme")
      assert Skins.style() =~ ~s([data-theme="pack-theme"]{color-scheme:light)
      assert Skins.style() =~ ~s([data-theme="pack-theme"][data-scheme="dark"])
    end

    test "a pack cannot shadow the built-in theme" do
      put_config(:skin_packs, [TestPack])
      put_config(:skins, [%{name: "default", colors: %{primary: "#ff0000"}}])

      assert Skins.get_theme("default").builtin?
      refute Skins.style() =~ "#ff0000"
    end

    test "drops unknown keys and unsafe values" do
      put_config(:skins, [
        %{
          name: "brand",
          colors: %{primary: "red; } body { display: none", secondary: "#0b5fff"},
          radius: %{nonsense: "1rem"}
        }
      ])

      css = Skins.style()

      refute css =~ "display: none"
      assert css =~ "--color-secondary:#0b5fff"
      refute css =~ "--radius-nonsense"
    end
  end

  describe "the theme the site wears" do
    test "is the configured seed when nothing is stored" do
      put_config(:theme, "fresh-blue")

      assert Skins.theme() == "fresh-blue"
    end

    test "a stored theme beats the seed" do
      put_config(:theme, "default")
      Settings.put_theme("fresh-blue", {:system, "test"})

      assert Skins.theme() == "fresh-blue"
    end

    test "falls back to default when the seed names nothing this site offers" do
      put_config(:theme, "no-such-theme")

      assert Skins.theme() == "default"
    end

    test "validate!/0 stops the release on a misspelt seed" do
      put_config(:theme, "fres-blue")

      assert_raise ArgumentError, ~r/is not a theme this site offers/, fn ->
        Skins.validate!()
      end
    end
  end

  describe "variants" do
    test "are system, light and dark — nothing else" do
      assert Enum.map(Skins.variants(), & &1.name) == ~w(system light dark)
    end

    test "pick the palette through the html attributes" do
      assert Skins.attributes("fresh-blue", "system") == %{"data-theme" => "fresh-blue"}

      assert Skins.attributes("fresh-blue", "dark") == %{
               "data-theme" => "fresh-blue",
               "data-scheme" => "dark"
             }

      assert Skins.attributes("default", "system") == %{}
      assert Skins.attributes("default", "dark") == %{"data-theme" => "dark"}
    end
  end

  describe "the reader's choice" do
    test "is a cookie and reaches the document", %{conn: conn} do
      html =
        conn
        |> Plug.Test.put_req_cookie("mirror_theme", "dark")
        |> get(~p"/")
        |> html_response(200)

      assert document_attributes(html) =~ ~s(data-scheme="dark")
    end

    test "an unknown variant falls back to system", %{conn: conn} do
      html =
        conn
        |> Plug.Test.put_req_cookie("mirror_theme", "neon")
        |> get(~p"/")
        |> html_response(200)

      refute document_attributes(html) =~ "data-scheme"
    end

    test "the header offers the three variants, not themes", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for variant <- ~w(system light dark) do
        assert html =~ ~s(href="/theme/#{variant}")
      end

      refute html =~ ~s(href="/theme/fresh-blue")
    end
  end

  describe "the variant route" do
    test "stores the variant in the cookie", %{conn: conn} do
      conn = get(conn, ~p"/theme/dark")

      assert conn.resp_cookies["mirror_theme"].value == "dark"
    end

    test "stores system for anything that is not a variant", %{conn: conn} do
      conn = get(conn, ~p"/theme/fresh-blue")

      assert conn.resp_cookies["mirror_theme"].value == "system"
    end
  end
end
