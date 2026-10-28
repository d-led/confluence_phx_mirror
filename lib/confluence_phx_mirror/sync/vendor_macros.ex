defmodule ConfluencePhxMirror.Sync.VendorMacros do
  @moduledoc """
  Third-party macros, one extension module per app.

  The marketplace's layout and formatting macros are the ones a mirror can draw
  honestly, because everything they need is on the page: a tab group wraps its
  tabs, a card grid wraps its cards, a title wraps its text. They are registered
  here by their `ac:name` and drawn by `Sync.VendorMacros.*` — one file per app,
  as a plugin belongs beside the others that speak the same vendor's dialect.

  What is **not** here is as deliberate as what is. A macro whose point is a live
  query (`table-filter`, `pivot-table`, `chart-from-table`), a writable form
  (`forms-by-adaptavist`, `confiform-*`) or a ticking clock cannot be drawn
  without the app and its data, and a static mirror that invented an answer would
  be lying about the source. Those fall back to `Sync.Renderer`, which keeps the
  macro's body and says what the thing was.
  """

  alias ConfluencePhxMirror.Sync.VendorMacros.{Adaptavist, Karma, SeibertAura}

  # The names are the vendors' own `ac:name` values: an app keyed prefix
  # (`aura-*`, `karma-*`, `confiform-*`) or the app's own word for the element.
  @extensions %{
    "aura-tab-group" => SeibertAura,
    "aura-tab" => SeibertAura,
    "aura-cards" => SeibertAura,
    "aura-title" => SeibertAura,
    "aura-progress-bar" => SeibertAura,
    "aura-countdown" => SeibertAura,
    "karma-section" => Karma,
    "karma-row" => Karma,
    "karma-column" => Karma,
    "tabs" => Adaptavist,
    "tab" => Adaptavist,
    "tooltip" => Adaptavist,
    "latex-block" => Adaptavist
  }

  @doc """
  The HTML for a vendor macro, or `:error` when no extension understands it.

      iex> draw("tooltip", %{"title" => "a hint"}, [])
      {:ok, [{"span", [{"class", "mirror-tooltip"}, {"title", "a hint"}], ["a hint"]}]}
  """
  @spec draw(String.t(), %{optional(String.t()) => String.t()}, [Floki.html_node()]) ::
          {:ok, [Floki.html_node()]} | :error
  def draw(name, parameters, body) do
    case Map.fetch(@extensions, String.downcase(name)) do
      {:ok, module} ->
        {:ok, module.draw(%{name: String.downcase(name), parameters: parameters, body: body})}

      :error ->
        :error
    end
  end

  @doc "Every vendor macro an extension draws, sorted."
  @spec names() :: [String.t()]
  def names, do: @extensions |> Map.keys() |> Enum.sort()
end
