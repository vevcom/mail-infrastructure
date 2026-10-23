# Setting it up in Dokploy

Step by step, from nothing to working mail. Do it on the **test domain**
first, in **relay mode** (the old omegaweb setup, least DNS work) - direct
mode can come later (section 8). Background for each step is in
[README.md](README.md) and [DNS.md](DNS.md).

Placeholders: `<domain>` is `WEBSITE_DOMAIN` (the test domain, or
`omega.ntnu.no`), `<server-ip>` the server's public IPv4 address.

## 0. Before you start

1. **The branch must be on the git remote.** Dokploy builds from git - push
   the branch you want to deploy.
2. **Optional: test locally** - the whole stack with a fake relay, nothing
   leaves your machine (README, "Testing with Mailpit"):
   ```sh
   docker network create dokploy-network   # one-time, if it doesn't exist yet
   docker compose -f docker-compose.test.yml --env-file .env.test up --build
   ```
3. **Ask NTNU IT** (can take days - start early):
   - Inbound **25** must reach the server - the Cloudflare Tunnel in front
     of the website only carries HTTP. In the OpenStack security group:
     relay mode, TCP 25 **only from NTNU's gateways** (`129.241.56.0/23` -
     README, "Security"); direct mode or a test domain whose MX points
     here, from `0.0.0.0/0`. Check that outbound traffic is allowed too
     (the default `Egress ... 0.0.0.0/0` rules).
   - Direct mode only (can wait until section 8): a **PTR** record for
     `<server-ip>` → `mail.omega.ntnu.no`, and later inbound 25 from the
     whole internet for the MX switch.

## 1. DNS, before deploying

4. Only needed if the MX will point at this server (the test domain, or
   direct mode) - harmless to add early:
   ```
   mail.<domain>.    A    <server-ip>
   ```
   omega.ntnu.no in relay mode: NTNU's gateways deliver to the mail host by
   name, so `sanctus.omega.ntnu.no.  A  <server-ip>` is what moves the mail
   to this server (DNS.md, "omega.ntnu.no - current values"). Change it only
   when this app is deployed and ready.

## 2. Create the app

5. In the **website's project** (the same environment as the website),
   **Create Service → Compose**.
6. **Provider**: this repository, the branch from step 1. **Compose path**:
   `docker-compose.prod.yml`.
7. Don't add a Dokploy **Domain** for `postfix` - SMTP doesn't go through
   Traefik. Leave "isolated deployment" off: the stack must be on
   `dokploy-network` to reach the website and its database.

## 3. Environment variables

8. Paste `.env.example` into the app's **Environment** tab and fill it in:

   | Variable | Value |
   |---|---|
   | `WEBSITE_DOMAIN` | the test domain, later `omega.ntnu.no` |
   | `EMAIL_HOSTNAME` | the website's `EMAIL_HOSTNAME` (prod: `sanctus.omega.ntnu.no`); empty = `mail.<domain>` |
   | `DELIVERY_MODE` | `relay` |
   | `EMAIL_RELAY_HOST` | `mailgw.ntnu.no` |
   | `SMTP_RELAY_USERNAME`, `SMTP_RELAY_PASSWORD` | empty (mailgw relays by source IP) |
   | `SMTP_SASL_AUTH_ENABLE` | `no` |
   | `SMTP_TLS_SECURITY_LEVEL` | `may` |
   | `DKIM_SELECTOR` | `mail` (direct mode only) |
   | `POSTGRES_HOST` | the website database's **Internal Host** (on the database's page in Dokploy) |
   | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | the same as in the website's `DB_URI` |
   | `SUBMISSION_USERNAME` | e.g. `website` |
   | `SUBMISSION_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` | each its own `openssl rand -base64 24` |

   If the project already has the Postgres credentials as shared
   (project-level) variables, reference those instead of copying them.

## 4. Free port 25 and deploy

9. **Stop whatever listens on port 25 now** - the old omegaweb postfix, or
   the other domain's mail app. Only one can have it.
10. **Deploy**.
11. Check the **postfix** logs (the app → Logs): `daemon started`, no
    `fatal:` lines. A Postgres error on the first lookup means `POSTGRES_*`
    is wrong, or the host isn't on `dokploy-network`.

## 5. The rest of the DNS records

12. **MX**:
    - omega.ntnu.no, relay mode: **leave it** at `mx.ntnu.no`.
    - The test domain: `<domain>.    MX    10 mail.<domain>.`
13. **DMARC** (recommended in relay mode, required in direct):
    ```
    _dmarc.<domain>.    TXT    "v=DMARC1; p=none; rua=mailto:dmarc@<domain>"
    ```
    and create `dmarc@<domain>` as a mail alias on the website, pointing at
    whoever reads the reports.

## 6. The website (optional in relay mode)

In relay mode the website can keep sending through its current provider.
To send through this postfix instead (needed in direct mode, section 8):

14. The connection is STARTTLS to postfix's **self-signed** certificate
    (README, "TLS"), so projectNext needs `EMAIL_TLS_ALLOW_SELF_SIGNED=true`
    (supported since vevcom/omegaweb-next#816) - without it, sending fails
    with a certificate error.
15. Set in projectNext's environment and redeploy the website:
    ```
    EMAIL_SERVER=mail-postfix
    EMAIL_PORT=25
    EMAIL_SECURE=false
    EMAIL_TLS_ALLOW_SELF_SIGNED=true
    EMAIL_USER=<SUBMISSION_USERNAME>
    EMAIL_PASSWORD=<SUBMISSION_PASSWORD>
    EMAIL_DOMAIN=<domain>
    EMAIL_HOSTNAME=<the mail app's EMAIL_HOSTNAME>
    ```
    `EMAIL_SERVER` is postfix's network alias - not the Dokploy app's name,
    which isn't a hostname (`getaddrinfo ENOTFOUND`). `EMAIL_HOSTNAME` is
    the second domain the website accepts for aliases and senders. Postfix
    only receives for and DKIM-signs `<domain>` and its own mail host, so
    the two apps must agree - like `EMAIL_PASSWORD`/`SUBMISSION_PASSWORD`, a
    project-level shared variable keeps them in sync.

## 7. Verify

16. **Unknown addresses**: mail to an alias that doesn't exist bounces
    straight back to the sender (`550 5.1.1 ... User unknown`). NTNU's
    gateways remember that answer for a few hours, so create aliases before
    testing them (DNS.md, "omega.ntnu.no - current values").
17. **Forwarding**: make your Gmail address a member of an alias, and send
    to the alias from a *different* account - Gmail hides mail that comes
    back to the account that sent it. It arrives, and the postfix log shows
    `nrcpt=<number of members>` and a `status=sent` line per member.
18. **Website mail** (if section 6 was done): trigger a notification to
    yourself.
19. **Grafana** (optional): give the `grafana` service a domain in Dokploy,
    port 3000, login `admin` / `GRAFANA_ADMIN_PASSWORD`. The Postfix
    dashboard shows the test messages.

More checks: DNS.md, "Verifying".

## 8. Direct mode (later, optional)

Follow DNS.md, "Rollout order" - the short version:

20. Check from the **server** that outbound port 25 is open:
    `nc -vz -w 5 gmail-smtp-in.l.google.com 25`. If it times out, stay on
    relay mode.
21. Ahead of time: `A mail.<domain>`, the **PTR** (step 3), **SPF** with
    `ip4:<server-ip>` added (DNS.md §4), **DMARC** (step 13), and lower the
    MX record's TTL to 300.
22. Set `DELIVERY_MODE=direct` (and `DKIM_SELECTOR`, default `mail`) and
    redeploy.
23. **DKIM**: the postfix log prints the record - publish it (DNS.md §5):
    ```
    mail._domainkey.<domain>.    TXT    "v=DKIM1; k=rsa; p=..."
    ```
    It's longer than 255 characters - split it into several quoted strings
    if the DNS editor wants that. The key lives on the `dkim-keys` volume:
    don't delete that volume.
24. Switch the **MX** to `mail.<domain>` (omega.ntnu.no: after NTNU IT has
    opened inbound port 25 from the internet).
25. Verify with Gmail's *Show original* (SPF, DKIM and DMARC all `PASS`) and
    [mail-tester.com](https://www.mail-tester.com) (aim for 9-10/10).
26. Point the website at postfix (section 6) - in direct mode its mail must go
    through here to be DKIM-signed. After 2-4 weeks of clean DMARC reports,
    tighten DMARC to `p=quarantine`, later `p=reject`.

## 9. Test → prod

27. Stop the test app, then repeat steps 5-19 for `omega.ntnu.no`, in the
    prod website's project. Both can't run at once on one server - they
    need the same port 25 (README, "Test and prod domains").
