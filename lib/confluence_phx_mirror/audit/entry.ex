defmodule ConfluencePhxMirror.Audit.Entry do
  @moduledoc """
  What happened, as the domain module that owns the change describes it.

  A page knows that a new version is a `page.updated`; a webhook delivery knows
  that an unknown event is `webhook.ignored`. Each of them builds an entry with
  an `audit_event_*` function, so the action name, the entity and the metadata
  shape live next to the thing they describe instead of at every call site.

  `ConfluencePhxMirror.Audit` is the only module that persists entries.
  """

  @enforce_keys [:action, :entity_type, :entity_id]
  defstruct [:action, :entity_type, :entity_id, metadata: %{}]

  @type t :: %__MODULE__{
          action: String.t(),
          entity_type: String.t(),
          entity_id: String.t() | integer(),
          metadata: map()
        }

  @doc false
  @spec new(String.t(), String.t(), String.t() | integer(), map()) :: t()
  def new(action, entity_type, entity_id, metadata \\ %{}) do
    %__MODULE__{
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      metadata: metadata
    }
  end
end
