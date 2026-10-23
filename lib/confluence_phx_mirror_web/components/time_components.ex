defmodule ConfluencePhxMirrorWeb.TimeComponents do
  @moduledoc """
  Timestamps a reader sees on their own clock.

  The server has no way of knowing the reader's time zone, and guessing one
  would be wrong for somebody. So the server renders the instant in UTC — the
  zone it stores and reasons in — and labels it as UTC. `assets/js/local_time.js`
  then rewrites the same instant in the browser's zone: the text of the element,
  or just its tooltip when the element already says "3 hours ago".
  """

  use Phoenix.Component

  import ConfluencePhxMirrorWeb.Time, only: [date: 1, datetime: 1, iso: 1]

  attr :at, :any,
    required: true,
    doc: "a `DateTime` in UTC, or `nil` when the mirror never saw the instant"

  attr :format, :atom,
    default: :datetime,
    values: [:date, :datetime],
    doc: "how much of the instant the text shows, once the browser has its way"

  attr :class, :string, default: nil
  attr :rest, :global

  slot :inner_block,
    doc: "text of your own, such as a relative time; the instant moves to the tooltip"

  @doc """
  An instant, in the shape the caller wants to show it.

      <.local_time at={@page.external_updated_at} />
      <.local_time at={@post.external_updated_at} format={:date} />
      <.local_time at={@page.synced_at}>{Time.ago(@page.synced_at)}</.local_time>
  """
  def local_time(assigns) do
    assigns = assign(assigns, :iso, iso(assigns.at))

    ~H"""
    <time
      datetime={@iso}
      data-local-time={if @inner_block == [], do: @format}
      data-local-title={@inner_block != []}
      title={datetime(@at)}
      class={@class}
      {@rest}
    >{if @inner_block == [], do: text(@at, @format), else: render_slot(@inner_block)}</time>
    """
  end

  defp text(nil, _format), do: "unknown"
  defp text(at, :date), do: date(at)
  defp text(at, :datetime), do: datetime(at)
end
