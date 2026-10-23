defmodule ConfluencePhxMirror.Confluence.FailingSource do
  @moduledoc """
  Test double for a source that cannot be reached at all.

  A run against it dies at the first listing, which is what the worker's retry
  behaviour is about: `Sync` records the run as failed and re-raises, so Oban
  sees an error rather than a completed job.
  """

  @behaviour ConfluencePhxMirror.Confluence.Source

  alias ConfluencePhxMirror.Confluence.DemoSource

  @impl true
  defdelegate name(), to: DemoSource

  @impl true
  defdelegate kind(), to: DemoSource

  @impl true
  def spaces(_opts), do: {:error, :unreachable}

  @impl true
  def changed_since(_since, _opts), do: {:error, :unreachable}

  @impl true
  defdelegate pages(space_key, opts), to: DemoSource

  @impl true
  defdelegate page(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate comments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachments(confluence_id, opts), to: DemoSource

  @impl true
  defdelegate attachment_data(attachment, opts), to: DemoSource
end
