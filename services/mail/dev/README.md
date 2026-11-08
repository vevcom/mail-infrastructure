# Mail in development

Stalwart, the mail server production is moving to, with [Mailpit](https://mailpit.axllent.org/) as
its relay: every mail for a domain the server does not host ends up in Mailpit's inbox instead of
leaving the machine. Stalwart is set up from `plan.ndjson` on every start, so the whole state is in
this directory, and `docker compose --profile mail down -v` resets it.

| | Address | Credentials |
|---|---|---|
| Stalwart admin | https://localhost:8443/admin | `admin` / `omegaweb-dev-admin` |
| Mailpit | http://localhost:8025 | none |
| IMAPS, for a mail client | `localhost:1993` | `dev@omegaweb.localhost` / `omegaweb-dev-mailbox` |
| Submission | `localhost:1465`, implicit TLS | the same mailbox |

The certificates are self-signed, so a client has to be told to accept them.

## What the plan sets up

- The domain `omegaweb.localhost`, and `mail.omegaweb.localhost` as the server's name.
- The mailbox `dev@omegaweb.localhost`, which the application sends from and a mail client logs in with.
- The list `styret@omegaweb.localhost`, with the mailbox and `someone@example.com` as members. A
  mail to it shows both deliveries: one copy in the mailbox, one in Mailpit.
- A relay route to Mailpit, and the outbound strategy that sends everything not local through it.
- A tracer to standard output, so `docker compose logs stalwart` shows what the server does.

## How an application connects

Over the compose network, to `stalwart` on port 465 with implicit TLS, authenticating as the
mailbox. Stalwart only accepts the account's own addresses as sender, so the application sends from
`dev@omegaweb.localhost`. omegaweb-next's `.env.default` holds these values: setting
`EMAIL_SERVER=stalwart` there is all it takes.

## Changing it

Edit `plan.ndjson` and run `up` again. Every line is an `upsert` keyed on the object's name or an
`update` of a singleton, so the plan converges and can be applied any number of times. Removing a
line does not remove the object from a running server, so after that, reset with `down -v`.

The `stalwart-provision` service is the CLI, so any other command runs through it:

```bash
docker compose --profile mail run --rm stalwart-provision describe Domain
docker compose --profile mail run --rm stalwart-provision query Account
```

## The domain

Stalwart refuses single-label names such as `localhost`, which is the mail domain omegaweb-next
derives from `sites.example.json`. Sending is unaffected, since the application sends from the
mailbox. Once omegaweb-next manages lists and accounts here, its development mail domain has to
become `omegaweb.localhost`, or another name with a dot that the plan hosts.
