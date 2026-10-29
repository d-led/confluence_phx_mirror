# Mail that works — Brevo as the example

The mirror sends two kinds of mail: sign-in links, and what watchers ask for
(instant updates and the daily digest). Nothing else. Mail is **optional**: with
no relay configured the deployment keeps Swoosh's *Local* adapter and mail is
written to a file instead of sent, and nothing else on the mirror changes.
(Development comes with a relay of its own — smtp4dev on `localhost:2525`, web UI
on <http://localhost:3001> — so the same paths can be watched without an
account.)

This page is the whole recipe for making it actually arrive, using Brevo as the
worked example. Another relay is the same five values — the variables are the
mirror's, not any provider's.

## 1. What to collect in Brevo

| Where in Brevo | What it is |
| --- | --- |
| **Senders & IP → Senders** | the address mail will be **from**, verified (green checkmark). Brevo refuses any other sender with a `550`. |
| **SMTP & API → SMTP** | the **server** (`smtp-relay.brevo.com`), the **port** (`587`), the **login** (`…@smtp-brevo.com`) and an **SMTP key**. |

The key is not your Brevo account password: generate it on that page. The login
is not the sender either — that is the single most common way this goes wrong,
so they travel as two different variables.

## 2. Translate them into the mirror's variables

| Brevo says | Set this |
| --- | --- |
| SMTP server `smtp-relay.brevo.com` | `SMTP_RELAY=smtp-relay.brevo.com` |
| port `587` | `SMTP_PORT=587` (the default) |
| login `…@smtp-brevo.com` | `SMTP_USERNAME=…@smtp-brevo.com` |
| SMTP key | `SMTP_PASSWORD=<the key>` |
| verified sender `mirror@your-domain.example` | `MIRROR_MAIL_FROM=mirror@your-domain.example` |
| a name for the inbox | `MIRROR_MAIL_FROM_NAME=Your Company Mirror` (optional) |

`SMTP_TLS` and `SMTP_AUTH` default to `always`, which is what a submission port
wants; leave them alone. Port `465` (implicit TLS) is **not** configured — use
`587`.

The sender is stamped on every message, including the test message below, so one
value covers sign-in links, watcher updates and the test.

## 3. Where to set them

### On Fly.io (secrets)

Secrets belong on the **mirror** app — the one `fly.toml` names. The
oauth2-proxy app never sends mail and needs none of this.

```sh
fly secrets set -a <the app in fly.toml> \
  SMTP_RELAY=smtp-relay.brevo.com \
  SMTP_PORT=587 \
  SMTP_USERNAME=…@smtp-brevo.com \
  SMTP_PASSWORD=<the SMTP key> \
  MIRROR_MAIL_FROM=mirror@your-domain.example \
  MIRROR_MAIL_FROM_NAME="Your Company Mirror"
```

Notes that save a round trip:

- `fly secrets set` restarts the machine, and the release reads these at boot —
  no redeploy needed. `scripts/fly-deploy.sh live` afterwards is harmless:
  secrets survive a deploy.
- Nothing is echoed back: `fly secrets list` shows names and a digest only.
- To hand the values over without restarting yet, add `--stage` and set them in
  force later with `fly secrets deploy`.
- A digest or sign-in link needs `CM_ADMINS` / the reader's account as well —
  mail is the transport, not the identity.

### In `docker compose`

`docker-compose.site.yml` takes the same variables in its `environment:` block
(next to `CM_ATL_EMAIL` and friends):

```yaml
    environment:
      SMTP_RELAY: smtp-relay.brevo.com
      SMTP_PORT: "587"
      SMTP_USERNAME: ${SMTP_USERNAME:?set SMTP_USERNAME}
      SMTP_PASSWORD: ${SMTP_PASSWORD:?set SMTP_PASSWORD}
      MIRROR_MAIL_FROM: ${MIRROR_MAIL_FROM:?set MIRROR_MAIL_FROM}
```

### Without a restart: `/admin/settings` → *Mail server*

An administrator can store the same values on the screen — relay, port,
username, password, sender address and sender name. A stored value wins over the
variable and takes effect on the next message, which is what makes a wrong relay
fixable without a deploy. The password is stored and never printed back; a blank
field keeps the one in force, and *Use the deployment's values* hands the group
back to the variables.

## 4. Prove it arrives

Sign in and open `/profile`: **Send me a test e-mail**. It sends one message to
your own address, at most one a minute per reader, and reports the relay's
answer. A refusal is shown verbatim — that message is the diagnosis.

| What it says | What it means |
| --- | --- |
| "Test e-mail sent to …" | the relay took it. If it does not arrive, look in the spam folder and check Brevo's *Statistics → Transactional → Logs*. |
| `550 … sender … not verified` | the sender in step 1 is not verified in Brevo, or is not the address in `MIRROR_MAIL_FROM`. |
| `auth_failed` | wrong `SMTP_USERNAME` / `SMTP_PASSWORD` — the key is an SMTP key, not the account password, and it is shown once. |
| `tls_failed` | the certificate did not verify. Rare; make sure `SMTP_RELAY` is the hostname Brevo gave you and `SMTP_PORT` is `587`. |
| nothing, and the log says Local adapter | `SMTP_RELAY` is empty, so the mirror is writing mail to a file. |

In development the same button is the way to see a mail in smtp4dev
(`docker compose up -d`, then <http://localhost:3001>).

## 5. Two switches that are not the same thing

- `SMTP_RELAY` (and the rest) — *how* mail leaves the mirror. Without it,
  nothing is sent.
- `MIRROR_NOTIFICATIONS` / `notifications.enabled` on `/admin/settings` —
  *whether watchers' e-mail is created at all*. Sign-in links and the test
  message ignore it: turning notifications off must never lock anyone out.

## How the connection is checked

TLS is verified against the relay's own name using the system's roots
(`verify: :verify_peer`, SNI = relay, hostname check, `depth: 99`). The depth is
not slack: a relay whose certificate chain carries a cross-signed root — Brevo's
does — fails OTP's default path length, and the handshake then looks like a
broken certificate rather than a policy. `Settings.mail_configuration/0` builds
those options for whichever relay is in force, stored or configured.
