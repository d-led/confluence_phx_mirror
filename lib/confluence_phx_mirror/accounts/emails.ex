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

  @doc """
  "An account exists for you" — the mail an administrator's pre-created account
  gets, which is the only thing that tells the person it exists.
  """
  def welcome(%User{} = user, opts) do
    site = Keyword.fetch!(opts, :site)
    sign_in = Keyword.get(opts, :sign_in)

    Swoosh.Email.new()
    |> from(from_address())
    |> to({User.display_name(user), user.email})
    |> subject("[Mirror] An account for you on #{site}")
    |> text_body("""
    Hi #{User.display_name(user)},

    #{site} has a read-only Confluence mirror, and an account has been made for
    this address.

    #{sign_in || "Sign in at #{mirror_address(opts)}, the way you sign in to Confluence."}

    If you were not expecting this, you can ignore it: nothing has been shared
    with you that you could not already read.
    """)
    |> html_body("""
    <div style="font-family: -apple-system, Segoe UI, Helvetica, Arial, sans-serif; max-width: 520px;">
      <h2>An account for you on #{escape(site)}</h2>
      <p>Hi #{escape(User.display_name(user))},</p>
      <p>A read-only mirror of the Confluence site exists, and an account has been made for this
      address.</p>
      #{sign_in_html(sign_in, mirror_address(opts))}
      <p style="color:#6b7280;font-size:12px;">If you were not expecting this, you can ignore it.</p>
    </div>
    """)
  end

  # The address of the mirror itself, or a phrase when the deployment does not
  # know its own (a mail with an empty link is worse than one without a link).
  defp mirror_address(opts) do
    case Keyword.get(opts, :url) do
      url when is_binary(url) and url != "" -> url
      _unknown -> "the mirror"
    end
  end

  defp sign_in_html(nil, "the mirror"), do: "<p>Sign in the way you sign in to Confluence.</p>"

  defp sign_in_html(nil, url), do: "<p><a href=\"#{escape(url)}\">#{escape(url)}</a></p>"

  defp sign_in_html(url, _site) when is_binary(url) do
    """
    <p><a href="#{escape(url)}" style="display:inline-block;padding:10px 16px;background:#0052cc;color:#fff;border-radius:6px;text-decoration:none;">Sign in</a></p>
    <p style="color:#6b7280;font-size:12px;">The link expires in 15 minutes and can be used once.</p>
    """
  end

  defp from_address do
    Application.get_env(:confluence_phx_mirror, :notifications, [])
    |> Keyword.get(:from, {"Confluence Mirror", "mirror@localhost"})
  end

  defp escape(text) do
    text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
  end
end
