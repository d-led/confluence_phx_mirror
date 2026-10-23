defmodule ConfluencePhxMirrorWeb.Skins do
  @moduledoc """
  The skins a site author can offer readers.

  Four skins ship with the mirror (`system`, `light`, `mirror`, `dark`), defined
  as daisyUI themes in `assets/css/app.css`. Every other skin is a *declaration*
  — a plain map, emitted into the page as a `[data-theme]` rule, so it needs no
  CSS edit and no asset rebuild.

  Declarations come from two places:

    * `config :confluence_phx_mirror, :skins` — maps for this deployment;
    * `config :confluence_phx_mirror, :skin_packs` — modules implementing
      `ConfluencePhxMirrorWeb.Skins.Pack`, the way a skin ships as a
      standalone extension (see `ConfluencePhxMirrorWeb.Skins.AtlassianCloud`).

  A declaration looks like this:

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

  A declaration may carry `dark_colors` as well. The skin then has two variants
  under one name and follows the reader's OS preference, exactly as `system`
  does:

      %{
        name: "brand",
        colors: %{base_100: "#ffffff"},
        dark_colors: %{base_100: "#111214"}
      }

  `selectable: false` keeps a skin out of the reader's picker: it is a *whole
  skin*, chosen by the deployment rather than by each reader. Pinning one for
  the whole site is `site_skin`, and `default_skin` is what a reader sees before
  they pick anything:

      config :confluence_phx_mirror, default_skin: "atlassian-cloud"
      config :confluence_phx_mirror, :site_skin, "atlassian-cloud"

  Anything the palette cannot express (fonts, component tweaks) goes in
  `assets/css/author.css`, which is loaded after the main stylesheet.
  """

  @type scheme :: :light | :dark

  @typedoc "A skin as declared in config or returned by a pack."
  @type declaration :: map()

  @type skin :: %{
          name: String.t(),
          label: String.t(),
          icon: String.t(),
          scheme: scheme() | nil,
          selectable?: boolean(),
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

  @doc """
  Built-in skins first, then the site's declarations in order: config, then
  each pack. The first declaration of a name wins, so a deployment can refine
  a pack's skin in config.
  """
  @spec all() :: [skin()]
  def all do
    builtin_skins() ++ custom()
  end

  @doc """
  The skins a reader may pick, in picker order.

  Empty when the site pins one skin for everyone (`site_skin/0`): the picker
  would offer choices that the site skin overrides anyway.
  """
  @spec reader_skins() :: [skin()]
  def reader_skins do
    if site_skin(), do: [], else: Enum.filter(all(), & &1.selectable?)
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
  The skin this deployment applies to every reader, or `nil` when readers
  choose their own. Set with `config :confluence_phx_mirror, :site_skin`.
  """
  @spec site_skin() :: String.t() | nil
  def site_skin do
    case Application.get_env(:confluence_phx_mirror, :site_skin) do
      "" -> nil
      name when is_binary(name) -> name
      _name -> nil
    end
  end

  @doc """
  The skin a reader sees before they pick one. `system` when the configured
  default is not a skin this site offers.

  This is not a site skin: the reader's cookie still wins, and the picker still
  offers every selectable skin.
  """
  @spec default_skin() :: String.t()
  def default_skin do
    name = Application.get_env(:confluence_phx_mirror, :default_skin, "system")
    if valid?(name), do: name, else: "system"
  end

  @doc """
  Fails fast when `:site_skin` or `:default_skin` names a skin this site does
  not offer.

  Called once at boot: a typo should stop the release, not quietly serve the
  wrong theme until someone notices.
  """
  @spec validate!() :: :ok
  def validate! do
    check!(:site_skin, site_skin())
    check!(:default_skin, Application.get_env(:confluence_phx_mirror, :default_skin))
  end

  defp check!(_key, nil), do: :ok

  defp check!(key, name) do
    cond do
      valid?(name) ->
        :ok

      true ->
        raise ArgumentError,
              "#{key} #{inspect(name)} is not a skin this site offers; " <>
                "available: #{Enum.join(names(), ", ")}"
    end
  end

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

  defp builtin_skins do
    Enum.map(@builtin, &Map.merge(&1, %{builtin?: true, selectable?: true}))
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
        selectable?: skin[:selectable] != false,
        builtin?: false,
        custom?: true,
        css: rule(name, scheme_css, declarations, dark_declarations(skin))
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

  # Only the colours change between variants; radii, border and depth are
  # shared, so the media query stays small and one palette cannot drift from
  # the other's geometry.
  defp dark_declarations(skin), do: palette(skin[:dark_colors])

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

  defp rule(_name, _scheme_css, [], _dark), do: ""

  defp rule(name, scheme_css, declarations, []) do
    variant(name, scheme_css, declarations)
  end

  defp rule(name, scheme_css, declarations, dark) do
    variant(name, scheme_css, declarations) <>
      "\n@media (prefers-color-scheme:dark){" <> variant(name, "dark", dark) <> "}"
  end

  defp variant(name, scheme_css, declarations) do
    "[data-theme=\"#{name}\"]{color-scheme:#{scheme_css};#{Enum.join(declarations, ";")}}"
  end
end
