# mail-infrastructure

Postfix mail server for the website's mail aliases (`<something>@<domain>`
→ the members behind it), plus monitoring. Deployed as a Dokploy compose app
alongside the website and its Postgres database - step by step in
[SETUP.md](SETUP.md).

Two compose files, so a plain `docker compose up` can't accidentally run
the wrong one:

- `docker-compose.prod.yml` - the real stack. Point Dokploy's compose file
  path at this one.
- `docker-compose.test.yml` - `include:`s `docker-compose.prod.yml`
  wholesale and overrides just the relay (see "Testing with Mailpit"
  below). Self-contained - `docker compose -f docker-compose.test.yml up`
  needs no other `-f`.

Naming: `WEBSITE_DOMAIN` is the mail domain (`<domain>`, e.g.
`omega.ntnu.no`) and the mail host is always `mail.<domain>` - derived in
`containers/postfix/entrypoint.sh`, not configured.

## Delivery modes

Picked with `DELIVERY_MODE`. Receiving is the same in both; the difference is
how mail leaves the server.

| | `relay` | `direct` |
|---|---|---|
| Outbound path | Everything goes through `EMAIL_RELAY_HOST` (NTNU's `mailgw.ntnu.no`) | Postfix delivers straight to each recipient's mail server |
| Same as | The old omegaweb postfix | - |
| Website's own mail (notifications, digest) | Optionally through this postfix, then out via mailgw (not DKIM-signed by us) | Through this postfix, DKIM-signed |
| Host requirements | On NTNU's network (mailgw relays by source IP) | Outbound port 25 open, fixed public IP with PTR, IP not blocklisted |
| Extra pieces | None | postsrsd (SRS), opendkim (DKIM), inbound spam checks |
| DNS work | Little - see [DNS.md](DNS.md) | SPF, DKIM, DMARC, PTR - see [DNS.md](DNS.md) |

**relay** reproduces the old setup exactly. Pick it for omega.ntnu.no while
the server is on NTNU's network.

**direct** is for when there's no relay to lean on. Everything that keeps
directly-sent mail out of spam folders is built in (verified end to end):

- **SRS** (postsrsd): forwarded mail from e.g. `someone@gmail.com` leaves with
  envelope sender `SRS0=...@<domain>`, so the recipient's SPF check is against
  our domain (which lists our IP) instead of gmail.com (which doesn't). The
  visible `From:` is untouched, and the original sender's DKIM signature
  survives, so DMARC still passes. Bounces to SRS addresses are rewritten
  back to the original sender.
- **DKIM** (opendkim): mail `From: @<domain>` / `@mail.<domain>` that comes
  from the website (authenticated) or from postfix itself (bounces) is signed
  with `d=<domain>`. Forwarded mail is left alone. A 2048-bit key is
  generated on first start and kept on the `dkim-keys` volume, one per
  domain. If opendkim is down, mail waits in the queue rather than going out
  unsigned.
- **Inbound checks**: in direct mode no NTNU spam filter sits in front, and
  every spam accepted for an alias gets forwarded from *our* IP. So unless
  the client is the website: HELO must be a valid FQDN, the sender domain
  must exist, the client must not be on Spamhaus ZEN, and nobody may use
  `<domain>` as sender (otherwise anyone could send "from"
  `noreply@<domain>` to an alias and we'd forward it with passing SPF).

## Mail flow

The website manages the alias tables directly in Postgres; Postfix only
ever reads them.

**Inbound** (to `<anything>@<domain>`):

1. Internet → `postfix:25` (directly, or via NTNU's `mx.ntnu.no` - see
   [DNS.md](DNS.md)).
2. The recipient is looked up via `virtual_alias_maps` against the website's
   Postgres (`containers/postfix/pgsql-aliases.cf.tmpl`). No match →
   rejected at `RCPT TO` time (no backscatter).
3. A match expands to the alias's members, and a copy goes out to each:
   through the relay (`relay`) or straight to their mail server (`direct`).

**Website's own mail** (either mode):

1. Website → `mail-postfix:25` (a stable alias on `dokploy-network`),
   authenticating with `SUBMISSION_USERNAME`/`SUBMISSION_PASSWORD` (AUTH
   PLAIN or LOGIN) after STARTTLS. Not network/CIDR-based trust:
   `dokploy-network` is shared with other things that shouldn't get relay
   access just by being on the same subnet. `mynetworks` is loopback-only;
   anything else must authenticate to send to a domain we don't own (see
   `smtpd_relay_restrictions` in `main.cf.tmpl`) - this has no effect on
   *receiving* mail for our own domain, which stays open to anyone.
2. Postfix hands it to the relay (`relay`), or DKIM-signs it and delivers
   it itself (`direct`).

## Spinning it up in Dokploy

### Common steps (both modes)

The full walkthrough - firewall, DNS, the Dokploy app, env, deploying,
the website, verifying - is [SETUP.md](SETUP.md). In short:

1. **Free port 25.** Only one thing per IP can listen on it - stop the old
   omegaweb postfix (or the other app, see below) first.
2. Create a **Compose** app from this repository, compose path
   `docker-compose.prod.yml`.
3. Set the environment variables (Dokploy → Environment) from
   `.env.example`:
   - `WEBSITE_DOMAIN` - `omega.ntnu.no`, or the test domain.
   - `POSTGRES_*` - the website's database: same host/credentials as the
     website's `DB_URI`. The host must be reachable on `dokploy-network`.
   - `SUBMISSION_USERNAME`/`SUBMISSION_PASSWORD` - any long random values
     (used by the website to send through this postfix).
   - `GRAFANA_ADMIN_PASSWORD`.
   - Then the mode-specific ones below.
4. Deploy, and check the postfix logs for `daemon started`.
5. Do the DNS records for the chosen mode: [DNS.md](DNS.md).
6. Optionally give Grafana a domain in Dokploy (it's the only HTTP service).

The host must accept port 25 straight from the internet (or from NTNU's
MX) - the Cloudflare Tunnel in front of the website only carries HTTP.

### relay mode

```
DELIVERY_MODE=relay
EMAIL_RELAY_HOST=mailgw.ntnu.no
SMTP_RELAY_USERNAME=
SMTP_RELAY_PASSWORD=
SMTP_SASL_AUTH_ENABLE=no
SMTP_TLS_SECURITY_LEVEL=may
```

Don't point `EMAIL_RELAY_HOST` at a sending service like SMTP2GO: forwarded
mail keeps the original sender (e.g. `someone@gmail.com`), and those
services only relay mail from domains you've verified with them.

The website can keep sending through its own provider, or send through this
postfix with the same website settings as under direct mode below. Its mail
then leaves via mailgw, which omega.ntnu.no's SPF already allows. It isn't
DKIM-signed in this mode.

### direct mode

Before switching, check from the **server** (not your laptop):

```sh
# Outbound port 25 must be open - many networks/providers block it.
nc -vz -w 5 gmail-smtp-in.l.google.com 25
# The server's public IP should have a PTR (reverse DNS) record - see DNS.md.
dig -x <server-ip> +short
```

If the first one times out, direct mode can't work from this host - stay on
relay mode (or ask the network owner to open it).

```
DELIVERY_MODE=direct
DKIM_SELECTOR=mail
```

(The `EMAIL_RELAY_HOST`/`SMTP_*` variables are ignored.)

After deploying, the postfix logs show the DKIM record to publish:

```
entrypoint: DKIM DNS record (TXT) - publish this, see DNS.md:
entrypoint:   name:  mail._domainkey.<domain>
entrypoint:   value: v=DKIM1; k=rsa; p=MIIBIjANBgkq...
```

It's printed on every start, and the key stays the same across redeploys
(it lives on the `dkim-keys` volume - don't delete that volume, or the
published record stops matching).

Then point the website at this postfix (projectNext env):

```
EMAIL_SERVER=mail-postfix
EMAIL_PORT=25
EMAIL_SECURE=false
EMAIL_TLS_ALLOW_SELF_SIGNED=true
EMAIL_USER=<SUBMISSION_USERNAME>
EMAIL_PASSWORD=<SUBMISSION_PASSWORD>
EMAIL_DOMAIN=<domain>
```

`EMAIL_TLS_ALLOW_SELF_SIGNED` is needed because postfix's certificate is
self-signed (see TLS below) - the connection is still encrypted, and it
never leaves the internal Docker network. projectNext doesn't read it yet:
its transport (`src/lib/email/constants.ts`) needs to turn it into
`tls: { rejectUnauthorized: false }`, or sending fails on the certificate.
Also set the website's `EMAIL_HOSTNAME=mail.<domain>` - it's the second
domain the website accepts for aliases and senders, and postfix only
receives for and signs `<domain>` and `mail.<domain>`.

## Test and prod domains

The test domain and omega.ntnu.no run on the same server, **one at a time**
(port 25 can only be bound once). Set them up as two separate Dokploy compose
apps from this repo - e.g. `mail-test` and `mail-prod` - each with its own
`WEBSITE_DOMAIN`, `POSTGRES_*` (the matching website's database) and
`DELIVERY_MODE`. Dokploy gives each app its own volumes, so DKIM keys, queue
and metrics stay separate.

To switch: stop the running app, then start the other. Each domain's DNS
records stay in place permanently - they don't need touching on a switch.

Both share the server's IP, and so its reputation: spam forwarded while
testing hurts prod's deliverability too. The IP's PTR record can only name
one host - see [DNS.md](DNS.md).

## The alias query

`containers/postfix/pgsql-aliases.cf.tmpl` has `hosts`/`user`/`password`/`dbname`
wired up to the `POSTGRES_*` env vars, and `query` ported directly from
`projectNext/containers/postfix/pgsql-aliases.cf.tmpl` (same schema - keep
the two identical). Given a `MailAlias.address`, it resolves to the union
of everything attached to that alias's `MailingList`:

- external addresses (`MailAddressExternal` via `MailingListMailAddressExternal`)
- direct members (`MailingListUser` → `User`), skipping archived users
- members of an attached group (`MailingListGroup` → `Group` → `Membership` → `User`),
  only active memberships, skipping archived users

Each matched row becomes one recipient, so one alias naturally expands
to multiple deliveries. This assumes that schema (`MailAlias`,
`MailingList`, `MailAddressExternal`, `MailingListMailAddressExternal`,
`MailingListUser`, `MailingListGroup`, `Group`, `Membership`, `User`)
already exists in whatever Postgres `POSTGRES_*` points at - if it doesn't
yet, lookups fail (logged, not fatal - Postfix only validates that `query`
is non-empty when `smtpd` opens the map, not that the tables it references
exist) until it does.

## DNS

Summary - the full guide with exact values is [DNS.md](DNS.md).

- **relay, omega.ntnu.no**: nothing new if NTNU keeps routing the domain's
  mail from `mx.ntnu.no` to this server (ask NTNU IT when the server or its
  IP changes); the existing SPF already covers mailgw.
- **relay, other domains / direct**: `A mail.<domain>`, `MX <domain>` →
  `mail.<domain>`.
- **direct** additionally: PTR, SPF, DKIM, DMARC (+ optional TLS-RPT).

## Logs

Postfix logs to `/var/log/postfix/maillog` (read by `postfix-exporter`),
mirrored to stdout so it also shows in Dokploy's log view. In direct mode,
opendkim's log lines (`DKIM-Signature field added ...`) go to stdout too.

## TLS

Inbound SMTP offers opportunistic STARTTLS with a self-signed certificate
generated at image build time (`containers/postfix/Dockerfile`). It's never
validated by connecting servers (`smtpd_tls_security_level = may`) - it just
encrypts the hop, which is all opportunistic TLS needs. Outbound mail uses
opportunistic STARTTLS as a client, no cert management needed on this side.
A CA-signed cert would only be needed for MTA-STS (see [DNS.md](DNS.md)).
Dokploy's automatic TLS (Traefik + Let's Encrypt) only covers HTTP(S) apps
behind it and never comes into play for Postfix's raw port-25 traffic -
Grafana (a plain HTTP app) is the one service here that can use Dokploy's
normal domain + TLS routing.

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
[Mailpit](https://mailpit.axllent.org/) container instead of NTNU's relay, so
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
hardcode (domain, `SUBMISSION_USERNAME`/`PASSWORD`, Grafana
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

Mailpit only covers relay mode. For direct mode and real delivery (does it
reach Gmail's inbox, do SPF/DKIM/DMARC pass?), use the test domain on the
real server - see "Verifying" in [DNS.md](DNS.md).

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
  were substituted, and the block for the chosen `DELIVERY_MODE` was used.
- With `DELIVERY_MODE=direct`: the logs print the DKIM record, and
  `docker compose exec postfix pgrep -l 'postsrsd|opendkim'` shows both
  running.
- Send a test message in on port 25 - expect a rejection for an unknown
  recipient (the alias table doesn't exist yet), logged to
  `/var/log/postfix/maillog`.
