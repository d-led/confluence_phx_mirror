# Renders every message the mirror can send to a file, so a person can look at
# them in a browser instead of signing off a colour scheme from source code.
#
#   MIX_ENV=test mix run scripts/dev/render-mails.exs [out_dir]
#
# Rows are built, not inserted: a preview needs the shape of a page and a
# reader, not a database. The test message is the exception — it is built inside
# `Mail`, so it is sent through the test adapter and read back out of the
# mailbox.

alias ConfluencePhxMirror.Accounts.{Emails, User}
alias ConfluencePhxMirror.Mail
alias ConfluencePhxMirror.Mirror.{Page, Space}
alias ConfluencePhxMirror.Notifications.{Email, Notification}

out_dir = System.argv() |> List.first() || Path.join([File.cwd!(), "tmp", "mails"])
File.mkdir_p!(out_dir)

site = "Confluence Mirror"
url = "https://mirror.example"

space = %Space{id: 1, key: "PLAT", name: "Platform"}
other_space = %Space{id: 2, key: "OPS", name: "Operations"}

page = fn space, id, title, slug, version ->
  %Page{
    id: id,
    confluence_id: 10_000 + id,
    title: title,
    slug: slug,
    version_number: version,
    space: space
  }
end

reader = %User{id: 7, email: "ada@example.com", display_name: "Ada Lovelace"}

notification = fn page, action, body ->
  %Notification{
    id: page.id,
    subject: "#{page.title} was #{action}",
    body: body,
    page: page
  }
end

one =
  notification.(
    page.(space, 1, "Deploying the mirror", "deploying-the-mirror", 12),
    "updated",
    "The rollback section now says what to do when the release command fails."
  )

many = [
  one,
  notification.(
    page.(space, 2, "Release checklist", "release-checklist", 31),
    "updated",
    "Two boxes about the mail relay were added."
  ),
  notification.(
    page.(other_space, 3, "On-call rotation", "on-call-rotation", 4),
    "created",
    "The winter rotation is published."
  )
]

render = fn email ->
  email.html_body |> IO.iodata_to_binary()
end

messages = [
  {"updates-one", render.(Email.updates(reader, [one]))},
  {"updates-many", render.(Email.updates(reader, many))},
  {"digest", render.(Email.digest(reader, many))},
  {"login-link", render.(Emails.login_link(reader, "#{url}/session/token/abc123"))},
  {"welcome-url", render.(Emails.welcome(reader, site: site, url: url))},
  {"welcome-link", render.(Emails.welcome(reader, site: site, sign_in: "#{url}/session/token/def456"))}
]

mail_test = fn ->
  :ok = Mail.send_test(reader)

  receive do
    {:email, email} -> [{"test-message", render.(email)}]
  after
    5_000 -> raise "the test message never reached the mailbox"
  end
end

for {name, html} <- messages ++ mail_test.() do
  path = Path.join(out_dir, name <> ".html")
  File.write!(path, html)
  IO.puts(path)
end
