# Mail in development

Stalwart, the mail server production runs, with [Mailpit](https://mailpit.axllent.org/) as its
relay and the [Bulwark](https://bulwarkmail.org/) webmail. Every mail for a domain the server does
not host ends up in Mailpit's inbox instead of leaving the machine. Stalwart is set up from
production's base plan and then `plan.ndjson` on every start, so the whole state is in git, and
`docker compose down -v` resets it.

| | Address | Credentials |
|---|---|---|
| Webmail | http://mail.omegaweb.localhost:8081 | your omegaweb-next account, see below |
| Stalwart admin | https://localhost:8443/admin | `admin` / `omegaweb-dev-admin` |
| Mailpit | http://localhost:8025 | none |
| IMAPS, for a mail client | `localhost:1993` | an app password, see below |
| Submission | `localhost:1465`, implicit TLS | an app password, see below |

Signing in goes through omegaweb-next, which is an OpenID Connect provider on
`http://auth.localhost:3000` when it runs with the `sites.json` of its example: the webmail sends
you there, and you come back signed in as `<username>@mail.omegaweb.localhost`, seeing the
mailboxes of the aliases you receive mail on. Stalwart reaches that address through
`auth.localhost`, which the compose file points at the machine. Passwords are refused everywhere
once the directory is active, see the root README, so a mail client takes an app password, made in
the webmail. `postmaster@omegaweb.localhost` is where the server's reports go and has no login.
The application has no account: it sends through a listener of its own, see below. The certificates on 8443, 1465 and 1993 are self-signed, so a client has to be told to
accept them; the webmail uses the plain listener on 8080.

## What the plans set up

The base plan, `../deploy/base/plan.ndjson`, is production's: logging to standard output, the
HTTP settings the webmail and a reverse proxy need, the listener the application sends through,
and the rule that someone signed in sends as their own addresses alone. This directory's plan
then sets up:

- The domain `omegaweb.localhost`, and `mail.omegaweb.localhost` as the server's name.
- The domains `career.localhost` and `revue.localhost`, the mail domains of the other sites in
  omegaweb-next's `sites.example.json`. The application creates no domain, so a site added to a
  local `sites.json` needs a line here for its aliases to work.
- A relay route to Mailpit, and the outbound strategy that sends everything not local through it.
- The `postmaster` mailbox.
- The domain `mail.omegaweb.localhost`, the webmail's host, where the accounts of those who sign
  in live, and `forward.mail.omegaweb.localhost`, where the lists the mailboxes forward to live.
- The directory that signs users in through omegaweb-next at `http://auth.localhost:3000`, and that
  authentication uses it. The same lines as production's, with the development values.
- The rule that refuses mail from outside for `forward.mail.omegaweb.localhost`, the domain of the
  lists the mailboxes forward to, see the root README.
- A reload, so every setting takes effect.

## How an application connects

Over the compose network, to `stalwart` on port 2525 for sending, SMTP with STARTTLS and no login, and
to the management api at `http://stalwart:8080` as `admin`. The base plan sets that listener up,
see the root README. Stalwart only opens it when it starts, so after the first `up` on a fresh
volume, run `docker compose restart stalwart` once. omegaweb-next's `.env.default` holds these
values: setting `EMAIL_SERVER` and `EMAIL_ADMIN_URL` there is all it takes. With
`EMAIL_WEBMAIL_URL` naming the webmail above, it then keeps a mailbox per alias, a group at the
alias's own address, and a list of the alias's members the mailbox forwards a copy to. So a mail
to an alias shows in the alias's mailbox in the webmail, and one delivery per member: in Mailpit
for an external address, in a mailbox here for a local one.

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
