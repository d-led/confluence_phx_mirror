defmodule ConfluencePhxMirror.Settings.CatalogueTest do
  @moduledoc """
  The catalogue is the settings screen's contract: a declared key that nobody
  presents is a setting an administrator cannot reach, and a key missing from
  the display order is one the screen would silently drop.
  """

  use ExUnit.Case, async: true

  alias ConfluencePhxMirror.Settings.Catalogue

  test "every declared setting is placed in the display order" do
    assert Enum.sort(Catalogue.keys()) == Catalogue.all() |> Map.keys() |> Enum.sort()
  end

  test "every declared setting is presented by exactly one interface" do
    presented =
      [:settings, :webhooks, :theme]
      |> Enum.flat_map(&Catalogue.groups/1)
      |> Enum.flat_map(& &1.keys)

    assert Enum.sort(presented) == Enum.sort(Catalogue.keys())
  end

  test "a group lists the reader's limits before the paging sizes" do
    reading = Enum.find(Catalogue.groups(:settings), &(&1.key == :reading))

    assert reading.keys ==
             ["reader.html_limit", "reader.api_limit", "reader.attachments_limit"] ++
               ["search.page_size", "search.default_limit", "search.max_results"]
  end

  test "a stored value is validated by its declared type" do
    assert Catalogue.fetch!("notifications.digest_hour_utc").type == :hour
    assert Catalogue.fetch!("webhook.enabled").type == :boolean
    assert Catalogue.fetch!("search.page_size").type == :pos_integer
  end
end
