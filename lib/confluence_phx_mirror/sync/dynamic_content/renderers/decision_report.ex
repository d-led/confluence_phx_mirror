defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.DecisionReport do
  @moduledoc """
  *Decision report*: the decisions a space records, with the page each one is on.

      <div class="mirror-macro" data-macro="decision-report" data-space="ENG"></div>

  See `Renderers.ItemReport` for what the report will and will not do.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Renderers.ItemReport}

  @impl true
  def render(attrs, %Context{} = context), do: ItemReport.draw(:decisions, attrs, context)
end
