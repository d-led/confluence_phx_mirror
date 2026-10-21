defmodule ConfluencePhxMirror.Accounts.Emails do
  @moduledoc "Transactional e-mails for reader accounts."

  import Swoosh.Email

  alias ConfluencePhxMirror.Accounts.User

  @doc "Single-use sign-in link."
  def login_link(%User{} = user, url) do
    Swoosh.Email.new()
    |> from(from_address())
    |> to({User.display_name(user), user.email})
    |> subject("[Mirror] Sign in")
    |> text_body("""
    Hi #{User.display_name(user)},

    use this link to sign in to the read-only Confluence mirror:

    #{url}

    The link expires in 15 minutes and can be used once. If you did not request
    it, you can ignore this e-mail.
    """)
    |> html_body("""
    <div style="font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; max-width: 520px;">
      <h2>Sign in to the mirror</h2>
      <p>Hi #{escape(User.display_name(user))},</p>
      <p><a href="#{escape(url)}" style="display:inline-block;padding:10px 16px;background:#0052cc;color:#fff;border-radius:6px;text-decoration:none;">Sign in</a></p>
      <p style="color:#6b7280;font-size:12px;">The link expires in 15 minutes and can be used once.</p>
    </div>
    """)
  end

  defp from_address do
    Application.get_env(:confluence_phx_mirror, :notifications, [])
    |> Keyword.get(:from, {"Confluence Mirror", "mirror@localhost"})
  end

  defp escape(text) do
    text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
  end
end
