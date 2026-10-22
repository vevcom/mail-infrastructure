# mail-infrastructure

Postfix mail relay + alias lookup + monitoring, deployed as a Dokploy project
alongside an existing webserver and its Postgres database.

Two compose files, so a plain `docker compose up` can't accidentally run
the wrong one:

- `docker-compose.prod.yml` - the real stack. Point Dokploy's compose file
  path at this one.
- `docker-compose.test.yml` - `include:`s `docker-compose.prod.yml`
  wholesale and overrides just the relay (see "Testing with Mailpit"
  below). Self-contained - `docker compose -f docker-compose.test.yml up`
  needs no other `-f`.

## Mail flow

The webserver only ever **sends** mail here - it has no mail-receiving
endpoint of its own, and never will. It manages the alias table directly in
Postgres (creates/edits/deletes rows); Postfix only ever reads it.

**Inbound** (DNS MX points directly at this host):

1. Internet → `postfix:25`.
2. The recipient address is looked up via `virtual_alias_maps`/`alias_maps`
   against the existing project's Postgres (`containers/postfix/pgsql-aliases.cf.tmpl`).
   No match → rejected at `RCPT TO` time (no backscatter).
3. A match resolves to a forwarding address, and the mail is re-sent out
   through `relayhost` to that address. There's no "deliver to the
   webserver" case - every resolved address goes back out through the relay.

**Outbound** (webserver sending mail):

1. Webserver → `postfix:25`, authenticating with `SUBMISSION_USERNAME`/
   `SUBMISSION_PASSWORD` (AUTH PLAIN or LOGIN). Not network/CIDR-based
   trust: `dokploy-network` is shared with other things in the same
   Dokploy project, and those shouldn't get relay access just by being on
   the same subnet. `mynetworks` is loopback-only; anything else must
   authenticate to relay to a domain we don't own (see
   `smtpd_relay_restrictions` in `main.cf.tmpl`) - this has no effect on
   *receiving* mail for our own domain, which stays open to anyone.
2. Postfix relays everything out through SMTP2GO (`relayhost` +
   `smtp_sasl_*`), which handles outbound delivery/reputation.

## The alias query

`containers/postfix/pgsql-aliases.cf.tmpl` has `hosts`/`user`/`password`/`dbname`
wired up to the `POSTGRES_*` env vars, and `query` ported directly from
`projectNext/containers/postfix/pgsql-aliases.cf.tmpl` (same schema). Given
a `MailAlias.address`, it resolves to the union of everything attached to
that alias's `MailingList`:

- external addresses (`MailAddressExternal` via `MailingListMailAddressExternal`)
- direct members (`MailingListUser` → `User`)
- members of an attached group (`MailingListGroup` → `Group` → `Membership` → `User`)

Each matched row becomes one RHS recipient, so one alias naturally expands
to multiple deliveries. This assumes that schema (`MailAlias`,
`MailingList`, `MailAddressExternal`, `MailingListMailAddressExternal`,
`MailingListUser`, `MailingListGroup`, `Group`, `Membership`, `User`)
already exists in whatever Postgres `POSTGRES_*` points at - if it doesn't
yet, lookups fail (logged, not fatal - Postfix only validates that `query`
is non-empty when `smtpd` opens the map, not that the tables it references
exist) until it does.

## Environment variables

See `.env.example`. Set these as the stack's environment variables in
Dokploy. `POSTGRES_*` should match whatever's already configured for the
project's existing Postgres instance — there is no dedicated database
container here. `SUBMISSION_USERNAME`/`SUBMISSION_PASSWORD` is whatever
credential you configure the webserver's outgoing mail client with - pick
any value, it's generated into postfix's SASL database at container
startup, not looked up anywhere else. `SMTP_SASL_AUTH_ENABLE`/
`SMTP_TLS_SECURITY_LEVEL` default to `yes`/`encrypt` for the real SMTP2GO
relay; `docker-compose.test.yml` overrides both for local testing (see
below).

## DNS records

Point the domain's MX record at this host (`EMAIL_HOSTNAME`). Since outbound
mail relays through SMTP2GO, also add SMTP2GO's recommended SPF/DKIM records
for the sending domain so outbound mail isn't flagged as spam — SMTP2GO's
dashboard provides the exact records to add.

## TLS

Inbound SMTP offers opportunistic STARTTLS with a self-signed certificate
generated at image build time (`containers/postfix/Dockerfile`). It's never
validated by connecting clients (`smtpd_tls_security_level = may`) - it just
encrypts the hop, which is all opportunistic TLS needs. Outbound mail to
SMTP2GO uses SMTP2GO's own TLS endpoint as a client, no cert management
needed on this side. Dokploy's automatic TLS (Traefik + Let's Encrypt) only
covers HTTP(S) apps behind it and never comes into play for Postfix's raw
port-25 MX traffic - Grafana (a plain HTTP app) is the one service here that
can use Dokploy's normal domain + TLS routing.

## Monitoring

`postfix-exporter` (`containers/postfix-exporter/Dockerfile`) builds
`kumina/postfix_exporter` from its own upstream source - no published image
exists for it on any registry, and its own Dockerfile is broken today
(pinned to `golang:1.16`, whose Debian base points at archived
`security.debian.org` paths - confirmed by testing). Our Dockerfile just
clones their repo and builds it with a current, maintained Go base image,
so it's still always building their real source, not a vendored copy of
their Go code - just not literally their own `Dockerfile`.

It reads two things from Postfix, both shared as read-only volumes:
`/var/log/postfix/maillog` (delivery/bounce/reject counters) and
`/var/spool/postfix` (the `showq` socket, for queue size/age metrics - the
exporter reports as "down" without it). Prometheus scrapes it; Grafana is
pre-provisioned with a Postfix dashboard (`containers/grafana/provisioning/dashboards/postfix.json`,
adapted from the public "Postfix" dashboard at
https://grafana.com/grafana/dashboards/10013-postfix/ with an added bounce-rate
panel) showing:

- Connect/disconnect rates, connections lost, SASL auth failures (health).
- Rejection ratio per daemon (problems).
- Queue size/age, message processing and delivery-delay rates (health).
- TLS protocol/cipher usage.
- **Bounce rate**: share of `smtp(8)` delivery attempts with
  `status=bounced` out of all delivery attempts.

Default Grafana login is `admin` / `GRAFANA_ADMIN_PASSWORD`.

### Data retention

- `postfix-log` volume: `maillog_file` has no built-in rotation, so it's
  rotated daily via `logrotate` + cron inside the `postfix` container
  (`containers/postfix/logrotate.conf`), keeping 7 compressed days.
- `prometheus-data` volume: bounded by Prometheus's own TSDB retention,
  set to 30 days (`--storage.tsdb.retention.time=30d` in `docker-compose.prod.yml`).
- `grafana-data` volume: just Grafana's own small sqlite state
  (dashboards/users/sessions) - negligible growth, nothing to manage.

## Testing with Mailpit (no real mail sent)

`docker-compose.test.yml` includes `docker-compose.prod.yml` wholesale and
overrides the relay to point at a local
[Mailpit](https://mailpit.axllent.org/) container instead of SMTP2GO, so
outbound mail never leaves the machine. Considered Ethereal Email first,
but it's a hosted third-party service requiring internet access and a
generated account per test run; Mailpit is a single local container,
needs no credentials or signup, and supports STARTTLS + "accept any" auth
by default, so it exercises the real relay path without needing a separate
plaintext code path just for testing. (MailHog, the older standard for
this, is unmaintained - Mailpit is its actively-maintained successor.)

```sh
docker network create dokploy-network   # one-time, if it doesn't exist yet
docker compose -f docker-compose.test.yml --env-file .env.test up --build
```

`.env.test` supplies the vars `docker-compose.test.yml` doesn't already
hardcode (hostname/domain, `SUBMISSION_USERNAME`/`PASSWORD`, Grafana
password). It points `POSTGRES_*` at a `test-postgres` container that
doesn't exist yet by default - alias lookups will temp-fail (451) until
you either start one (a one-liner is in `.env.test`'s comments) or point
it at a real Postgres with a matching row. Then:

- Send a test message in on port 25, authenticating first (`mynetworks` is
  loopback-only, so an external test client must AUTH to relay - see the
  worked example below) - e.g. a small Python socket script, or `swaks
  --auth-user test --auth-password test`.
  ```python
  import socket, time, base64
  s = socket.create_connection(("postfix", 25), timeout=10)
  s.recv(4096)
  s.sendall(b"EHLO test.local\r\n"); time.sleep(0.3); s.recv(4096)
  auth = base64.b64encode(b"\x00test\x00test").decode()  # SUBMISSION_USERNAME/PASSWORD
  s.sendall(f"AUTH PLAIN {auth}\r\n".encode()); time.sleep(0.3); print(s.recv(4096))
  s.sendall(b"MAIL FROM:<test@external.example>\r\n"); time.sleep(0.3); s.recv(4096)
  s.sendall(b"RCPT TO:<someone@example.com>\r\n"); time.sleep(0.3); print(s.recv(4096))
  s.sendall(b"DATA\r\nSubject: test\r\n\r\nHello.\r\n.\r\n"); time.sleep(0.5); print(s.recv(4096))
  s.sendall(b"QUIT\r\n")
  ```
- Open http://localhost:8025 - Mailpit's web UI shows the captured message
  if the alias resolved, or check `docker compose logs postfix` for the
  temp-fail rejection if it didn't.
- `docker compose exec postfix-exporter wget -qO- localhost:9154/metrics`
  shows `postfix_*` series updating.
- Prometheus `/targets` - exporter target is `UP`.
- Grafana - Postfix dashboard loads and shows data from the test message.

## Local verification (without Mailpit)

```sh
docker compose -f docker-compose.prod.yml config
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up
```

With dummy env vars (point `POSTGRES_*` at a throwaway local Postgres if
needed):

- `docker compose logs postfix` - no fatal errors, templates rendered.
- `docker compose exec postfix cat /etc/postfix/main.cf` - confirms env vars
  were substituted.
- Send a test message in on port 25 - expect a rejection for an unknown
  recipient (the alias table doesn't exist yet), logged to
  `/var/log/postfix/maillog`.
