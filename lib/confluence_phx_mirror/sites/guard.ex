defmodule ConfluencePhxMirror.Sites.Guard do
  @moduledoc """
  Checks at boot that the database belongs to the configured site.

  A mirror that silently served one site's content under another site's
  configuration would be worse than one that refuses to sync, so the default is
  to crash the application when the two disagree: a server has no one to ask and
  must not start half-configured.

  A window is the exception, and passes `on_conflict: :report`. There is a person
  in front of it, they cannot read a console, and a crash dump is not an
  explanation — so the disagreement is logged and left where a screen can show
  it, and the tool starts. Syncing still refuses: `Sync` calls `Sites.verify!/0`
  per run, which is the place that matters, because reading never mixes sites and
  only a write can.
  """

  use GenServer

  require Logger

  alias ConfluencePhxMirror.Sites

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case {Sites.check(), Keyword.get(opts, :on_conflict, :stop)} do
      {:ok, _whatever} ->
        {:ok, %{site: Sites.key()}}

      {:unrecorded, _whatever} ->
        # A catalogue nothing has been written to yet: there is no site to
        # disagree with, and stamping one here is what made a fresh machine
        # claim to belong to the demo.
        {:ok, %{site: Sites.key()}}

      {:no_schema, _whatever} ->
        Logger.warning(
          "mirror_sites is missing; run the migrations before syncing, " <>
            "the site check is skipped until then"
        )

        {:ok, %{site: nil}}

      {{:conflict, recorded, configured}, :stop} ->
        # Raised from here rather than returned: the message is the one an
        # operator needs, and an application that will not start says it once,
        # loudly.
        raise Sites.conflict_message(recorded, configured)

      {{:conflict, recorded, configured}, :report} ->
        Sites.report_conflict!(recorded, configured)
        {:ok, %{site: Sites.key(), conflict: Sites.conflict()}}
    end
  end
end
