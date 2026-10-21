defmodule ConfluencePhxMirrorWeb.Skins do
  @moduledoc """
  The skins a site author can offer readers.

  Four skins ship with the mirror (`system`, `light`, `mirror`, `dark`), defined
  as daisyUI themes in `assets/css/app.css`. A site adds its own by declaring
  them in config — no CSS edit, no asset rebuild:

      config :confluence_phx_mirror, :skins, [
        %{
          name: "acme",
          label: "Acme",
          icon: "hero-building-office",
          scheme: :light,
          colors: %{
            base_100: "#ffffff",
            base_content: "#12243b",
            primary: "#0b5fff",
            primary_content: "#ffffff"
          },
          radius: %{box: "0.75rem", field: "0.375rem"}
        }
      ]

  The palette is emitted into the page as a `[data-theme]` rule, so the theme
  picker, the cookie and every daisyUI component pick it up. Declaring
  `scheme: :dark` also switches native controls and the code-token palette.

  Anything the palette cannot express (fonts, component tweaks) goes in
  `assets/css/author.css`, which is loaded after the main stylesheet.
  """

  @type scheme :: :light | :dark

  @type skin :: %{
          name: String.t(),
          label: String.t(),
          icon: String.t(),
          scheme: scheme() | nil,
          builtin?: boolean(),
          custom?: boolean(),
          css: String.t()
        }

  @builtin [
    %{name: "system", label: "System", icon: "hero-computer-desktop", scheme: nil},
    %{name: "light", label: "Light", icon: "hero-sun", scheme: :light},
    %{name: "mirror", label: "Mirror", icon: "hero-sparkles", scheme: :light},
    %{name: "dark", label: "Dark", icon: "hero-moon", scheme: :dark}
  ]

  @colors ~w(base_100 base_200 base_300 base_content
             primary primary_content secondary secondary_content
             accent accent_content neutral neutral_content
             info info_content success success_content
             warning warning_content error error_content)

  @radii ~w(selector field box)

  @name_pattern ~r/^[a-z][a-z0-9-]{0,31}$/
  # Values are author-supplied config, but they end up inside a <style> element,
  # so anything that could close the rule or the element is refused.
  @unsafe ~r/[;{}<>"'\n\r]/

  @doc "Built-in skins first, then the skins declared by the site, in config order."
  @spec all() :: [skin()]
  def all do
    builtin = Enum.map(@builtin, &Map.put(&1, :builtin?, true))
    builtin ++ custom()
  end

  @doc "Every selectable skin name, used to validate the theme cookie."
  @spec names() :: [String.t()]
  def names, do: Enum.map(all(), & &1.name)

  @doc "Looks a skin up by the name stored in the cookie."
  @spec get(String.t() | nil) :: skin() | nil
  def get(name), do: Enum.find(all(), &(&1.name == name))

  @doc "Whether `name` is a skin this site offers."
  @spec valid?(String.t() | nil) :: boolean()
  def valid?(name), do: not is_nil(get(name))

  @doc """
  The `[data-theme]` rules for site-declared skins.

  Built-in skins are already in the compiled stylesheet, so only custom skins
  are emitted. Returns an empty string when the site declares none.
  """
  @spec style() :: String.t()
  def style do
    custom()
    |> Enum.map(& &1.css)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp custom do
    :confluence_phx_mirror
    |> Application.get_env(:skins, [])
    |> Enum.map(&normalise/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalise(skin) when is_map(skin) do
    name = to_string(skin[:name] || "")
    label = to_string(skin[:label] || name)

    if valid_name?(name) and not Enum.any?(@builtin, &(&1.name == name)) do
      {scheme, scheme_css} = scheme(skin[:scheme])
      declarations = declarations(skin)

      %{
        name: name,
        label: label,
        icon: icon(skin[:icon]),
        scheme: scheme,
        builtin?: false,
        custom?: true,
        css: rule(name, scheme_css, declarations)
      }
    end
  end

  defp normalise(_skin), do: nil

  defp valid_name?(name), do: Regex.match?(@name_pattern, name)

  defp scheme(:dark), do: {:dark, "dark"}
  defp scheme(:light), do: {:light, "light"}
  defp scheme("dark"), do: {:dark, "dark"}
  defp scheme(_scheme), do: {:light, "light"}

  defp icon(nil), do: "hero-swatch"
  defp icon("hero-" <> _ = icon), do: icon
  defp icon(_icon), do: "hero-swatch"

  defp declarations(skin) do
    colours = palette(skin[:colors])
    radii = radii(skin[:radius])

    extras =
      [{"--border", skin[:border]}, {"--depth", skin[:depth]}, {"--noise", skin[:noise]}]
      |> Enum.filter(fn {_name, value} -> safe_value?(value) end)
      |> Enum.map(fn {name, value} -> "#{name}:#{String.trim(value)}" end)

    colours ++ radii ++ extras
  end

  defp palette(colors) when is_map(colors) do
    colors
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.filter(fn {key, value} -> key in @colors and safe_value?(value) end)
    |> Enum.map(fn {key, value} ->
      "--color-#{String.replace(key, "_", "-")}:#{String.trim(value)}"
    end)
  end

  defp palette(_colors), do: []

  defp radii(radii) when is_map(radii) do
    radii
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.filter(fn {key, value} -> key in @radii and safe_value?(value) end)
    |> Enum.map(fn {key, value} -> "--radius-#{key}:#{String.trim(value)}" end)
  end

  defp radii(_radii), do: []

  defp safe_value?(value) when is_binary(value) do
    trimmed = String.trim(value)
    trimmed != "" and String.length(trimmed) <= 120 and not Regex.match?(@unsafe, trimmed)
  end

  defp safe_value?(_value), do: false

  defp rule(_name, _scheme_css, []), do: ""

  defp rule(name, scheme_css, declarations) do
    "[data-theme=\"#{name}\"]{color-scheme:#{scheme_css};#{Enum.join(declarations, ";")}}"
  end
end
