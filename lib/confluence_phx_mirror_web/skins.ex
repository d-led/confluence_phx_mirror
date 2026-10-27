defmodule ConfluencePhxMirrorWeb.Skins do
  @moduledoc """
  What the mirror looks like: one **theme** for the whole site, and a
  **variant** each reader picks.

  A theme is the brand — the palette pair behind every screen. Two ship with the
  mirror:

    * `default` — the warm light palette and the violet dark one, compiled into
      `assets/css/app.css` as daisyUI themes;
    * `fresh-blue` — a skin pack (`ConfluencePhxMirrorWeb.Skins.FreshBlue`) that
      is emitted per request, light and dark together.

  An administrator chooses the theme for everyone on `/admin/settings`; the
  choice is stored by `ConfluencePhxMirror.Settings` and seeded by config
  (`:theme`, `CM_THEME`) when nothing is stored.

  A variant is the reader's own setting — `system`, `light` or `dark` — kept in
  a cookie. `system` follows the OS. Both end up as attributes on `<html>`:
  `data-theme` names the theme, `data-scheme` forces a palette for a theme that
  is not compiled in:

      <html data-theme="fresh-blue" data-scheme="dark">

  A pack adds a theme by returning a declaration with both palettes:

      %{
        name: "brand",
        label: "Brand",
        note: "one line for the admin's picker",
        colors: %{...},       # light
        dark_colors: %{...},  # dark; falls back to `colors` when absent
        radius: %{box: "0.5rem"}
      }

  Declarations come from `config :confluence_phx_mirror, :skins` (maps) and
  `config :confluence_phx_mirror, :skin_packs` (modules implementing
  `ConfluencePhxMirrorWeb.Skins.Pack`). Supported colour keys are the daisyUI
  colour names (`base_*`, `primary`, `secondary`, `accent`, `neutral`, `info`,
  `success`, `warning`, `error`, each with `_content`), the three radii, plus
  `border`, `depth` and `noise`; unknown keys and values that are not plain CSS
  are ignored.

  Anything a palette cannot express (fonts, component tweaks) goes in
  `assets/css/author.css`.
  """

  alias ConfluencePhxMirror.Settings

  @type variant :: %{name: String.t(), label: String.t(), icon: String.t()}

  # What a pack (or a `:skins` entry in config) declares: a palette pair and the
  # name to choose it by, plus the shape overrides daisyUI reads. It becomes a
  # `theme()` once the registry is built.
  @type declaration :: %{
          required(:name) => String.t(),
          required(:label) => String.t(),
          optional(:note) => String.t(),
          optional(:colors) => %{optional(atom()) => String.t()},
          optional(:dark_colors) => %{optional(atom()) => String.t()},
          optional(:radius) => %{optional(atom()) => String.t()},
          optional(:border) => String.t() | number(),
          optional(:depth) => String.t() | number(),
          optional(:noise) => String.t() | number()
        }

  @type theme :: %{
          name: String.t(),
          label: String.t(),
          note: String.t(),
          builtin?: boolean(),
          css: String.t()
        }

  @builtin_themes [
    %{
      name: "default",
      label: "Default",
      note: "warm light, violet dark",
      builtin?: true,
      css: ""
    }
  ]

  @variants [
    %{name: "system", label: "System", icon: "hero-computer-desktop"},
    %{name: "light", label: "Light", icon: "hero-sun"},
    %{name: "dark", label: "Dark", icon: "hero-moon"}
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

  @doc "The themes an administrator can choose, built-in first."
  @spec themes() :: [theme()]
  def themes, do: @builtin_themes ++ custom()

  @doc "Whether `name` is a theme this site offers."
  @spec theme?(String.t() | nil) :: boolean()
  def theme?(name), do: Enum.any?(themes(), &(&1.name == name))

  @doc "Looks a theme up by name."
  @spec get_theme(String.t() | nil) :: theme() | nil
  def get_theme(name), do: Enum.find(themes(), &(&1.name == name))

  @doc """
  The theme this site uses: what an administrator stored, else the configured
  seed, else `default`.
  """
  @spec theme() :: String.t()
  def theme do
    name = Settings.theme() || configured_theme()
    if theme?(name), do: name, else: "default"
  end

  @doc "The reader's own setting: `system`, `light` or `dark`."
  @spec variants() :: [variant()]
  def variants, do: @variants

  @doc "Whether `name` is a variant a reader can pick."
  @spec variant?(String.t() | nil) :: boolean()
  def variant?(name), do: Enum.any?(@variants, &(&1.name == name))

  @doc """
  The attributes `<html>` needs to paint `theme` in `variant`.

  A compiled-in theme swaps daisyUI's own `data-theme`; an emitted theme keeps
  its name and forces the palette with `data-scheme`.
  """
  @spec attributes(String.t(), String.t()) :: %{optional(String.t()) => String.t()}
  def attributes("default", "system"), do: %{}
  def attributes("default", "light"), do: %{"data-theme" => "light"}
  def attributes("default", "dark"), do: %{"data-theme" => "dark"}
  def attributes(theme, "system"), do: %{"data-theme" => theme}
  def attributes(theme, variant), do: %{"data-theme" => theme, "data-scheme" => variant}

  @doc """
  The `[data-theme]` rules for emitted themes.

  Built-in themes are already in the compiled stylesheet, so only pack and
  config themes are emitted. Returns an empty string when none are declared.
  """
  @spec style() :: String.t()
  def style do
    custom()
    |> Enum.map(& &1.css)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @doc """
  Fails fast when the configured seed names a theme this site does not offer.

  Called once at boot: a typo should stop the release, not quietly paint the
  default theme until someone notices.
  """
  @spec validate!() :: :ok
  def validate! do
    case configured_theme() do
      nil ->
        :ok

      name ->
        if theme?(name) do
          :ok
        else
          raise ArgumentError,
                "theme #{inspect(name)} is not a theme this site offers; " <>
                  "available: #{Enum.map_join(themes(), ", ", & &1.name)}"
        end
    end
  end

  defp configured_theme do
    case Application.get_env(:confluence_phx_mirror, :theme) do
      "" -> nil
      name when is_binary(name) -> name
      _name -> nil
    end
  end

  defp custom do
    declarations()
    |> Enum.map(&normalise/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.name)
  end

  defp declarations do
    site = Application.get_env(:confluence_phx_mirror, :skins, [])
    packs = Application.get_env(:confluence_phx_mirror, :skin_packs, [])

    site ++ Enum.flat_map(packs, & &1.skins())
  end

  defp normalise(theme) when is_map(theme) do
    name = to_string(theme[:name] || "")
    label = to_string(theme[:label] || name)

    if valid_name?(name) and not Enum.any?(@builtin_themes, &(&1.name == name)) do
      light = declarations_for(theme, theme[:colors])
      dark = declarations_for(theme, theme[:dark_colors] || theme[:colors])

      %{
        name: name,
        label: label,
        note: to_string(theme[:note] || ""),
        builtin?: false,
        css: rule(name, light, dark)
      }
    end
  end

  defp normalise(_theme), do: nil

  defp valid_name?(name), do: Regex.match?(@name_pattern, name)

  defp declarations_for(theme, colors) do
    colours = palette(colors)
    radii = radii(theme[:radius])

    extras =
      [{"--border", theme[:border]}, {"--depth", theme[:depth]}, {"--noise", theme[:noise]}]
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

  defp rule(_name, [], _dark), do: ""

  defp rule(name, light, dark) do
    selector = ~s([data-theme="#{name}"])

    [
      "#{selector}{color-scheme:light;#{Enum.join(light, ";")}}",
      "#{selector}[data-scheme=\"dark\"]{color-scheme:dark;#{Enum.join(dark, ";")}}",
      "@media (prefers-color-scheme:dark){#{selector}:not([data-scheme]){color-scheme:dark;" <>
        "#{Enum.join(dark, ";")}}}"
    ]
    |> Enum.join("\n")
  end
end
