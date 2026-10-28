defmodule ConfluencePhxMirror.Sync.VendorMacros.Karma do
  @moduledoc """
  Karma's page builder: sections, rows and columns.

  Karma is a layout engine, and a mirror has no viewport to lay out for — so the
  one thing worth preserving is the grouping, as ordinary `div`s with a class per
  element. The body keeps its order, which is all a static reader needs.
  """

  @behaviour ConfluencePhxMirror.Sync.VendorMacros.Extension

  @layout ~w(karma-section karma-row karma-column)

  @impl true
  def draw(%{name: name, body: body}) when name in @layout do
    [{"div", [{"class", "mirror-layout " <> name}], body}]
  end
end
