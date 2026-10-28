defmodule ConfluencePhxMirror.Sync.VendorMacros.SeibertAura do
  @moduledoc """
  Seibert Media's *Aura* formatting suite: tabs, cards, titles, a progress bar.

  All of it is page-local — the wrapper says how the content should look, and
  the content is in the macro's own body — so the mirror draws the semantics and
  leaves the polish to CSS: a tab group becomes `<details>` elements that open
  without JavaScript, a card grid becomes a grid of its cards.

  The one that cannot be drawn honestly is the countdown: it is a clock, and a
  clock baked into a page at sync time is wrong a minute later. It says which
  date it counts to instead, which is the part a reader needs from a mirror.
  """

  @behaviour ConfluencePhxMirror.Sync.VendorMacros.Extension

  @impl true
  def draw(%{name: "aura-tab-group", body: body}) do
    [{"div", [{"class", "mirror-aura-tabs"}], body}]
  end

  def draw(%{name: "aura-tab", parameters: parameters, body: body}) do
    [
      {"details", [{"class", "mirror-aura-tab"}, {"open", "open"}],
       [{"summary", [], [label(parameters)]} | body]}
    ]
  end

  def draw(%{name: "aura-cards", body: body}) do
    [{"div", [{"class", "mirror-aura-cards"}], body}]
  end

  # Aura's title is a heading by another name, and its level is the whole point
  # of it, so the parameter decides the tag.
  def draw(%{name: "aura-title", parameters: parameters, body: body}) do
    [{"h3", [{"class", "mirror-aura-title"}], [Map.get(parameters, "title", "") | body]}]
  end

  def draw(%{name: "aura-progress-bar", parameters: parameters}) do
    value = parameters |> Map.get("value", "0") |> percent()

    [
      {"div", [{"class", "mirror-progress"}, {"role", "progressbar"}, {"aria-valuenow", value}],
       [{"span", [{"style", "width: #{value}%"}], [value <> "%"]}]}
    ]
  end

  def draw(%{name: "aura-countdown", parameters: parameters}) do
    target = Map.get(parameters, "date", Map.get(parameters, "targetDate", "an unstated date"))

    [
      {"p", [{"class", "mirror-dynamic-notice"}],
       [
         "This macro counts down to #{target}. A static mirror cannot tick, so the date is all it has."
       ]}
    ]
  end

  # The macro's value is whatever the author typed; a number outside 0..100 is a
  # bar that cannot be drawn, so it is held to the ends rather than trusted.
  defp percent(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number |> max(0) |> min(100) |> Integer.to_string()
      :error -> "0"
    end
  end

  defp label(%{"title" => title}) when title != "", do: title
  defp label(%{"label" => label}) when label != "", do: label
  defp label(_parameters), do: "Tab"
end
