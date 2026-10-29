defmodule ConfluencePhxMirror.Mail do
  @moduledoc """
  The mail a reader may ask the mirror for, beyond what it sends on its own.

  A mirror mails sign-in links and watchers' updates, and until now nobody could
  find out whether those arrive: a digest that never shows up looks exactly like
  a quiet week, and a relay that refuses the sender looks like nothing at all.
  So every reader may send themselves one message, which is the whole of what
  this module is for.

  One a minute per reader: enough to retry after a typo, not enough to turn the
  deployment's relay into somebody's amplifier.
  """

  import Swoosh.Email

  alias ConfluencePhxMirror.Accounts.User
  alias ConfluencePhxMirror.Mail.Budget
  alias ConfluencePhxMirror.{Mailer, Settings}

  @window_ms 60_000

  @doc """
  Mails `user` a test message at their own address.

    * `:ok` — the relay took it (or, without a relay, it was written to the
      development mailbox, which is the answer the caller needed too);
    * `{:error, :paused}` — an administrator stopped the mail queue, so nothing
      was sent;
    * `{:error, :too_soon, retry_after_ms}` — nothing was sent;
    * `{:error, :spent, seconds}` — the provider's day is spent, and the number
      is the seconds until there is room for another message;
    * `{:error, reason}` — the relay refused it, and `reason` is what it said.
  """
  @spec send_test(User.t()) ::
          :ok
          | {:error, :paused}
          | {:error, :too_soon, pos_integer()}
          | {:error, :spent, pos_integer()}
          | {:error, term()}
  def send_test(%User{} = user) do
    with :ok <- queue_draining?(),
         :ok <- not_too_soon(user) do
      deliver(user)
    end
  end

  # One a minute, measured from the last message rather than from a clock
  # bucket: a bucket that turns over lets two through a second apart when they
  # straddle the boundary, which is not what "one a minute" says. The ledger
  # already knows when the last one went, so the window costs one query.
  defp not_too_soon(user) do
    case Budget.last_test_at(user) do
      nil ->
        :ok

      at ->
        waited = DateTime.diff(DateTime.utc_now(), at, :millisecond)

        if waited >= @window_ms, do: :ok, else: {:error, :too_soon, @window_ms - waited}
    end
  end

  # A test message is a message: an operator who stopped the queue stopped this
  # too, or the switch means nothing.
  defp queue_draining? do
    if Settings.mail_paused?(), do: {:error, :paused}, else: :ok
  end

  defp deliver(user) do
    case Mailer.send(message(user), Budget.key(:test, user), {:user, user}) do
      {:ok, _receipt} ->
        :ok

      # A test message is a message like any other: it takes one of the day's
      # allowance, and the screen can say why nothing arrived.
      {:error, :spent, seconds} ->
        {:error, :spent, seconds}

      # The same reader asking twice within the same minute: the key carries the
      # minute, so the relay is asked once.
      {:error, :already_sent} ->
        {:error, :too_soon, @window_ms}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp message(user) do
    name = User.display_name(user)

    Swoosh.Email.new()
    |> from(Mailer.sender())
    |> to({name, user.email})
    |> subject("[Mirror] Test e-mail")
    |> text_body("""
    Hi #{name},

    this is a test message from the Confluence mirror. It is the only thing it
    is for: if you are reading it, mail from this mirror reaches this address.

    Sent #{now()} because you asked for it. Watchers' updates and sign-in links
    come from the same sender.

    If you did not ask for it, somebody used your signed-in account — nothing
    else can send this.
    """)
    |> html_body(
      ConfluencePhxMirror.Mail.Layout.message(
        "Confluence Mirror",
        "This is a test message",
        "<p style=\"margin:0 0 4px;\">Hi #{escape(name)},</p>" <>
          "<p style=\"margin:0;\">Mail from the Confluence mirror reaches this address. Watchers' updates and sign-in links come from the same sender.</p>" <>
          ConfluencePhxMirror.Mail.Layout.muted("Sent #{escape(now())} because you asked for it."),
        footer:
          "If you did not ask for it, somebody used your signed-in account — nothing else can send this."
      )
    )
  end

  # What tells a reader at a glance whether the relay is instant or slow, which
  # is the other half of "does mail from here reach me".
  defp now, do: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")

  defp escape(text) do
    text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
  end
end
