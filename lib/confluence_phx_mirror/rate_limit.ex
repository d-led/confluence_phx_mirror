defmodule ConfluencePhxMirror.RateLimit do
  @moduledoc """
  ETS-backed rate limiter used for readers (HTML, API and attachments).

  Client-side limits protect Confluence; these limits protect the mirror's own
  database and bandwidth. Limits are configurable per scope.
  """

  use Hammer, backend: :ets
end
