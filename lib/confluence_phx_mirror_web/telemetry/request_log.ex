defmodule ConfluencePhxMirrorWeb.Telemetry.RequestLog do
  @moduledoc """
  One readable line per request, and nothing for the ones nobody reads.

  Fly probes `/health` every fifteen seconds per Machine; a log stream that
  records those is mostly probe. The probe already reports trouble the way a
  monitor can act on — it answers 503 — so it stays out of the log, and its
  absence from the log is itself the signal that the Machine is healthy.

  This replaces `Phoenix.Logger` (`config :phoenix, :logger, false`). Phoenix
  logs every request and offers no way to skip one path, which is all this
  adds; the line is the same shape, with method, path, status and duration on
  one line instead of two:

      GET /spaces 200 in 12.4ms
  """

  require Logger

  @event [:phoenix, :endpoint, :stop]
  @handler {__MODULE__, :request}

  # Anything a load balancer polls rather than a reader opens.
  @quiet ~w(/health /health/ready)

  @doc "Attaches the handler once; a second call is a no-op."
  def attach do
    case :telemetry.attach(@handler, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc false
  def handle_event(_event, measurements, %{conn: conn}, _config) do
    path = conn.request_path

    if path in @quiet do
      :ok
    else
      Logger.info(
        "#{conn.method} #{path} #{conn.status || 500} in #{duration(measurements)}",
        request_id: Logger.metadata()[:request_id]
      )
    end
  end

  defp duration(%{duration: native}) do
    case System.convert_time_unit(native, :native, :microsecond) do
      micros when micros >= 1_000 -> "#{Float.round(micros / 1_000, 1)}ms"
      micros -> "#{micros}µs"
    end
  end
end
