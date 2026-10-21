defmodule ConfluencePhxMirror.Repo do
  use Ecto.Repo,
    otp_app: :confluence_phx_mirror,
    adapter: Ecto.Adapters.Postgres
end
