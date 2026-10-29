defmodule ConfluencePhxMirror.Mail.Layout do
  @moduledoc """
  The frame every message the mirror sends shares.

  Tables and inline styles, because that is what mail clients render: a
  stylesheet in the head is dropped by half of them and a flexbox by the other
  half, so the layout is the one that has been working since 2003 — a centred
  table, a fixed width, and no hope that anything outside the tag will apply.

  The colours are the site's own: a very light blue page, a white card, one
  accent for whatever the reader is meant to press. A message should look like
  it came from this mirror rather than from a template somebody found.
  """

  @page "#eef4fa"
  @card "#ffffff"
  @line "#d7e6f7"
  @wash "#f6fafe"
  @ink "#12263a"
  @body "#1f2a37"
  @muted "#5a6b7d"
  @accent "#0052cc"
  @quote "#f4f9fe"
  @quote_rule "#7fb3df"

  @doc """
  Wraps `inner` in the frame, under a title and a line saying where it is from.

  `:footer` is the small print at the foot — why this message arrived, and
  anything the reader needs to know before ignoring it.
  """
  @spec message(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def message(site, title, inner, opts \\ []) do
    footer = Keyword.get(opts, :footer, "")

    # The card is 100% wide with a 600px ceiling, so a phone gets the whole
    # width rather than a table that only fits a desktop.
    """
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#{@page};margin:0;padding:24px 12px;">
      <tr>
        <td align="center">
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="width:100%;max-width:600px;background:#{@card};border:1px solid #{@line};border-radius:14px;overflow:hidden;font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;">
            <tr><td style="background:#{@accent};height:4px;line-height:4px;font-size:0;">&nbsp;</td></tr>
            <tr>
              <td style="padding:20px 24px 4px;">
                <p style="margin:0;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#{@muted};">#{site}</p>
                <h1 style="margin:6px 0 0;font-size:20px;line-height:1.3;color:#{@ink};">#{title}</h1>
              </td>
            </tr>
            <tr>
              <td style="padding:10px 24px 22px;font-size:14px;line-height:1.55;color:#{@body};">
                #{inner}
              </td>
            </tr>
            #{foot(footer)}
          </table>
        </td>
      </tr>
    </table>
    """
  end

  defp foot(""), do: ""

  defp foot(footer) do
    """
    <tr>
      <td style="padding:14px 24px;background:#{@wash};border-top:1px solid #{@line};font-size:12px;line-height:1.5;color:#{@muted};">
        #{footer}
      </td>
    </tr>
    """
  end

  @doc "The one thing a reader is meant to press, in the accent colour."
  @spec button(String.t(), String.t()) :: String.t()
  def button(label, url) do
    """
    <p style="margin:18px 0;">
      <a href="#{url}" style="display:inline-block;padding:11px 18px;background:#{@accent};color:#ffffff;border-radius:8px;text-decoration:none;font-weight:600;">#{label}</a>
    </p>
    """
  end

  @doc """
  Something quoted from the page: a changed page's own words, kept apart from
  the message about them.
  """
  @spec quote(String.t()) :: String.t()
  def quote(text) do
    """
    <div style="margin:14px 0;padding:12px 14px;background:#{@quote};border-left:3px solid #{@quote_rule};border-radius:8px;white-space:pre-wrap;font-size:13px;line-height:1.5;color:#{@body};">#{text}</div>
    """
  end

  @doc "A quiet line under something: when it expires, why it arrived."
  @spec muted(String.t()) :: String.t()
  def muted(text) do
    ~s(<p style="margin:10px 0 0;font-size:12px;line-height:1.5;color:#{@muted};">#{text}</p>)
  end

  @doc """
  One page in a list: what it is, the way in, and where it lives.

  `title` is what a reader presses, `meta` the quiet line under it — the space
  and the version it is now. `detail` is what changed, for a message that is
  meant to be read rather than skimmed; a burst leaves it out, because a
  hundred of them is a hundred paragraphs nobody asked for.
  """
  @spec card(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def card(title, url, meta, detail \\ "") do
    """
    <div style="margin:0 0 10px;padding:10px 12px;background:#{@wash};border:1px solid #{@line};border-radius:10px;">
      <p style="margin:0 0 2px;font-size:13px;font-weight:600;">
        <a href="#{url}" style="color:#{@accent};text-decoration:none;">#{title}</a>
      </p>
      <p style="margin:0;font-size:12px;color:#{@muted};">#{meta}</p>
      #{detail_line(detail)}
    </div>
    """
  end

  defp detail_line(""), do: ""

  defp detail_line(detail) do
    "<p style=\"margin:6px 0 0;font-size:13px;line-height:1.5;color:#{@body};\">#{detail}</p>"
  end

  @doc "The colours, for a test that asks whether a message wears the site's frame."
  @spec palette() :: %{atom() => String.t()}
  def palette do
    %{
      page: @page,
      card: @card,
      line: @line,
      wash: @wash,
      ink: @ink,
      body: @body,
      muted: @muted,
      accent: @accent,
      quote: @quote,
      quote_rule: @quote_rule
    }
  end
end
