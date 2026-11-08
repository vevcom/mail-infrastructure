# Mail in development

Stalwart, the mail server production runs, with [Mailpit](https://mailpit.axllent.org/) as its
relay and the [Bulwark](https://bulwarkmail.org/) webmail. Every mail for a domain the server does
not host ends up in Mailpit's inbox instead of leaving the machine. Stalwart is set up from
production's base plan and then `plan.ndjson` on every start, so the whole state is in git, and
`docker compose down -v` resets it.

| | Address | Credentials |
|---|---|---|
| Webmail | http://localhost:8081 | a mailbox below |
| Stalwart admin | https://localhost:8443/admin | `admin` / `omegaweb-dev-admin` |
| Mailpit | http://localhost:8025 | none |
| IMAPS, for a mail client | `localhost:1993` | a mailbox below |
| Submission | `localhost:1465`, implicit TLS | a mailbox below |

Mailboxes: `postmaster@omegaweb.localhost` with the password `omegaweb-dev-mailbox` comes from the
plan. `dev@omegaweb.localhost` with the same password is the application's, which omegaweb-next
creates when it syncs, see below. The certificates on 8443, 1465 and 1993 are self-signed, so a
client has to be told to accept them; the webmail uses the plain listener on 8080.

## What the plans set up

The base plan, `../deploy/base/plan.ndjson`, is production's: logging to standard output, and the
HTTP settings the webmail and a reverse proxy need. This directory's plan then sets up:

- The domain `omegaweb.localhost`, and `mail.omegaweb.localhost` as the server's name.
- A relay route to Mailpit, and the outbound strategy that sends everything not local through it.
- That the application's account may send as any address, since it sends as its aliases.
- The `postmaster` mailbox.
- A reload, so every setting takes effect.

## How an application connects

Over the compose network, to `stalwart` on port 465 with implicit TLS, authenticating as its
account, and to the management api at `http://stalwart:8080` as `admin`. omegaweb-next's
`.env.default` holds these values: setting `EMAIL_SERVER` and `EMAIL_ADMIN_URL` there is all it
takes. It then creates its account and a mailing list per alias, with the alias's members as
recipients, so a mail to an alias shows one delivery per member: in Mailpit for an external
address, in a mailbox here for a local one.

## Changing it

Edit `plan.ndjson` and run `up` again. Every line is an `upsert` keyed on the object's name or an
`update` of a singleton, so the plan converges and can be applied any number of times. Removing a
line does not remove the object from a running server, so after that, reset with `down -v`.

The `stalwart-provision` service is the CLI, so any other command runs through it:

```bash
docker compose run --rm stalwart-provision describe Domain
docker compose run --rm stalwart-provision query MailingList
```

## The domain

Stalwart refuses single-label names such as `localhost`, so omegaweb-next's development domain is
`omegaweb.localhost`, which browsers resolve to the machine itself.
