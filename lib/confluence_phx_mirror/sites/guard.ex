defmodule ConfluencePhxMirror.Sites.Guard do
  @moduledoc """
  Checks at boot that the database belongs to the configured site.

  A mirror that silently served one site's content under another site's
  configuration would be worse than one that refuses to start, so this crashes
  the application when the two disagree.
  """

  use GenServer

  require Logger

  alias ConfluencePhxMirror.Sites

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case Sites.verify!() do
      :ok ->
        {:ok, %{site: Sites.key()}}

      :no_schema ->
        Logger.warning(
          "mirror_sites is missing; run the migrations before syncing, " <>
            "the site check is skipped until then"
        )

        {:ok, %{site: nil}}
    end
  end
end
