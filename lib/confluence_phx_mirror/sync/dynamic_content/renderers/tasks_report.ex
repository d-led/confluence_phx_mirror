defmodule ConfluencePhxMirror.Sync.DynamicContent.Renderers.TasksReport do
  @moduledoc """
  *Task report*: the tasks of a space, with the page each one lives on.

      <div class="mirror-macro" data-macro="tasks-report" data-space="ENG"></div>

  See `Renderers.ItemReport` for what the report will and will not do.
  """

  @behaviour ConfluencePhxMirror.Sync.DynamicContent.Renderer

  alias ConfluencePhxMirror.Sync.DynamicContent.{Context, Renderers.ItemReport}

  @impl true
  def render(attrs, %Context{} = context), do: ItemReport.draw(:tasks, attrs, context)
end
