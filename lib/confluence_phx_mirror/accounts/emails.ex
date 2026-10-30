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
    |> html_body(
      ConfluencePhxMirror.Mail.Layout.message(
        "Confluence Mirror",
        "Sign in to the mirror",
        "<p style=\"margin:0 0 4px;\">Hi #{escape(User.display_name(user))},</p>" <>
          "<p style=\"margin:0;\">This link signs you in to the read-only Confluence mirror.</p>" <>
          ConfluencePhxMirror.Mail.Layout.button("Sign in", escape(url)) <>
          ConfluencePhxMirror.Mail.Layout.muted(
            "The link expires in 15 minutes and can be used once."
          ),
        footer: "If you did not request it, you can ignore this e-mail."
      )
    )
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
    |> html_body(
      ConfluencePhxMirror.Mail.Layout.message(
        "Confluence Mirror",
        "An account for you on #{escape(site)}",
        "<p style=\"margin:0 0 4px;\">Hi #{escape(User.display_name(user))},</p>" <>
          "<p style=\"margin:0;\">A read-only mirror of the Confluence site exists, and an account has been made for this address.</p>" <>
          sign_in_html(sign_in, mirror_address(opts)),
        footer: "If you were not expecting this, you can ignore it."
      )
    )
  end

  @doc """
  "A Confluence identity is now linked to this account."

  The same note serves both ends of a link, because the question is the same on
  both: which account holds this identity now, and what did that change? It is
  written about the two in the third person, so an inbox reading it as the
  account's or as the identity's is reading the truth.

  `identity` is what `ConfluencePhxMirror.Mirror.identity_details/1` answered —
  an account id, an address when the site listed one, and a name — and `:to` is
  the `{name, address}` the message is for.
  """
  def identity_linked(%User{} = user, identity, opts) do
    {name, _address} = to = Keyword.fetch!(opts, :to)
    identity_label = identity_label(identity)
    account = user.email

    Swoosh.Email.new()
    |> from(from_address())
    |> to(to)
    |> subject("[Mirror] A Confluence identity was linked")
    |> text_body("""
    Hi #{name},

    the Confluence identity #{identity_label} is now linked to the mirror account
    for #{account}.

    A link widens what that account may read here: everything the identity may
    read on the Confluence site becomes readable through it, and nothing else.
    Unlinking takes it away again.

    If you were not expecting this, tell an administrator of the mirror.
    """)
    |> html_body(
      ConfluencePhxMirror.Mail.Layout.message(
        "Confluence Mirror",
        "A Confluence identity was linked",
        "<p style=\"margin:0 0 4px;\">Hi #{escape(name)},</p>" <>
          "<p style=\"margin:0;\">The Confluence identity <strong>#{escape(identity_label)}</strong> is now linked to the mirror account for #{escape(account)}.</p>" <>
          "<p style=\"margin:8px 0 0;\">A link widens what that account may read here: everything the identity may read on the Confluence site becomes readable through it, and nothing else. Unlinking takes it away again.</p>",
        footer: "If you were not expecting this, tell an administrator of the mirror."
      )
    )
  end

  # A name says who, an account id says which: the message carries both, because
  # the reader has to be able to tell "yes, that is my guest account" from "no,
  # and I want it undone".
  defp identity_label(identity) do
    case identity.display_name do
      nil -> identity.account_id
      name -> "#{name} — #{identity.account_id}"
    end
  end

  # The address of the mirror itself, or a phrase when the deployment does not
  # know its own (a mail with an empty link is worse than one without a link).
  defp mirror_address(opts) do
    case Keyword.get(opts, :url) do
      url when is_binary(url) and url != "" -> url
      _unknown -> "the mirror"
    end
  end

  defp sign_in_html(nil, "the mirror"),
    do: "<p style=\"margin:12px 0 0;\">Sign in the way you sign in to Confluence.</p>"

  # A button says what pressing it does; the address is a line under it, for a
  # reader who would rather copy it than trust a link.
  defp sign_in_html(nil, url) do
    ConfluencePhxMirror.Mail.Layout.button("Open the mirror", escape(url)) <>
      ConfluencePhxMirror.Mail.Layout.muted(escape(url))
  end

  defp sign_in_html(url, _site) when is_binary(url) do
    ConfluencePhxMirror.Mail.Layout.button("Sign in", escape(url)) <>
      ConfluencePhxMirror.Mail.Layout.muted(
        "The link expires in 15 minutes and can be used once."
      )
  end

  defp from_address do
    Application.get_env(:confluence_phx_mirror, :notifications, [])
    |> Keyword.get(:from, {"Confluence Mirror", "mirror@localhost"})
  end

  defp escape(text) do
    text |> to_string() |> Plug.HTML.html_escape() |> IO.iodata_to_binary()
  end
end
