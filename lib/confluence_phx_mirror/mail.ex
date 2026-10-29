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
  alias ConfluencePhxMirror.{Mailer, RateLimit}

  @window_ms 60_000
  @per_window 1

  @doc """
  Mails `user` a test message at their own address.

    * `:ok` — the relay took it (or, without a relay, it was written to the
      development mailbox, which is the answer the caller needed too);
    * `{:error, :too_soon, retry_after_ms}` — nothing was sent;
    * `{:error, reason}` — the relay refused it, and `reason` is what it said.
  """
  @spec send_test(User.t()) :: :ok | {:error, :too_soon, pos_integer()} | {:error, term()}
  def send_test(%User{} = user) do
    case RateLimit.hit(key(user), @window_ms, @per_window) do
      {:allow, _count} -> deliver(user)
      {:deny, retry_after_ms} -> {:error, :too_soon, retry_after_ms}
    end
  end

  defp deliver(user) do
    case Mailer.deliver(message(user)) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> {:error, reason}
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
    |> html_body("""
    <div style="font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; max-width: 520px;">
      <h2 style="margin: 0 0 8px;">This is a test message</h2>
      <p>Hi #{escape(name)},</p>
      <p>Mail from the Confluence mirror reaches this address. Watchers' updates and
      sign-in links come from the same sender.</p>
      <p style="color:#6b7280;font-size:12px;">Sent #{escape(now())} because you asked for it.</p>
    </div>
    """)
  end

  # What tells a reader at a glance whether the relay is instant or slow, which
  # is the other half of "does mail from here reach me".
  defp now, do: Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M UTC")

  defp key(%User{id: id}), do: "mail:test:user:#{id}"

  defp escape(text) do
    text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
  end
end
