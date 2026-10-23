# Mail DNS and deliverability

Which DNS records the mail server needs, why, and how to keep mail out of
spam folders. Written for any `<domain>`; notes specific to the prod domain
(omega.ntnu.no) are marked **omega.ntnu.no**.

Placeholders:

- `<domain>` - the mail domain (`WEBSITE_DOMAIN`): the test domain, or `omega.ntnu.no`.
- `mail.<domain>` - the mail server's hostname: `EMAIL_HOSTNAME`, default `mail.<domain>`
  (**omega.ntnu.no**: `sanctus.omega.ntnu.no`, see README "Naming").
- `<server-ip>` - the server's public IPv4 address.
- `<selector>` - `DKIM_SELECTOR` (default `mail`).

Where records are edited:

- **omega.ntnu.no** is its own DNS zone, edited at
  [dnsadmin.itea.ntnu.no](https://dnsadmin.itea.ntnu.no) (access granted by NTNU
  IT; the zone's contact address is vevcom@omega.ntnu.no).
- The test domain: wherever its DNS is hosted (registrar / DNS provider).
- **PTR** (reverse DNS) is not part of either zone - it belongs to whoever
  owns the IP address: NTNU IT for NTNU addresses (129.241.x.x), otherwise the
  hosting provider.

## How receivers decide what's spam

Gmail, Outlook etc. combine several signals. Roughly in order of importance
for a small server:

1. **IP reputation** - has this IP sent spam before, is it on a blocklist,
   is it a home/dynamic address? A new IP has no reputation yet (see
   "Warming up").
2. **PTR / FCrDNS** - the IP's reverse DNS name (PTR) must exist and resolve
   back to the same IP ("forward-confirmed reverse DNS"). Ideally it matches
   the name the server introduces itself with (HELO = `mail.<domain>`).
   Gmail rejects mail from IPs without it.
3. **SPF** - a TXT record on the sender's domain listing which IPs may send
   for it. Checked against the *envelope* sender (the hidden "return path"),
   not the visible From.
4. **DKIM** - a cryptographic signature in the message headers, made with a
   private key on the server; the public key is in DNS. Proves the message
   came from the domain and wasn't altered.
5. **DMARC** - a policy record that ties SPF/DKIM to the *visible* From:
   at least one of them must pass **and** be for the same domain as the From
   address ("alignment"). It also tells receivers what to do on failure, and
   where to send reports.
6. **Content and complaints** - spammy content, users clicking "report
   spam", mail to addresses that don't exist.

How this server handles each, in **direct** mode:

| | Website's own mail (`noreply@<domain>`) | Forwarded alias mail (`someone@gmail.com` → alias → member) |
|---|---|---|
| SPF | Passes for `<domain>` (our IP is listed) | SRS rewrites the envelope sender to `SRS0=...@<domain>`, so it passes for `<domain>` |
| DKIM | Signed by us, `d=<domain>` | The original sender's signature (e.g. gmail.com) is kept intact |
| DMARC | Passes: SPF and DKIM both align with `From: @<domain>` | Passes via the original DKIM signature, which aligns with the original From |

In **relay** mode, NTNU's mailgw sends everything, so most of this is NTNU's
job - see the table below.

## What each mode needs

| Record | relay | direct |
|---|---|---|
| `A mail.<domain>` | Needed if MX points at it | **Required** |
| `MX <domain>` | **omega.ntnu.no**: keep `mx.ntnu.no`. Other domains: `mail.<domain>` | **Required**: `mail.<domain>` |
| PTR for `<server-ip>` | - | **Required** |
| SPF on `<domain>` | **omega.ntnu.no**: already correct | **Required** |
| SPF on `mail.<domain>` | Optional | Recommended |
| DKIM | - (the website's provider signs its own mail) | **Required** |
| DMARC | Recommended | **Required** (start at `p=none`) |
| TLS-RPT | Optional | Optional |
| MTA-STS | Not now (see below) | Not now (see below) |

### omega.ntnu.no - current values (checked 2026-10-22)

```
omega.ntnu.no.          MX   10 mx.ntnu.no.
omega.ntnu.no.          TXT  "v=spf1 redirect=_spfmailgw.ntnu.no"
omega.ntnu.no.          A    129.241.100.34          (the current server)
mail.omega.ntnu.no.     -    does not exist yet
_dmarc.omega.ntnu.no.   -    none (so ntnu.no's p=none policy applies)
DNSSEC                  -    not signed (ntnu.no isn't either)
```

So today mail for omega.ntnu.no is received by NTNU's own mail gateway
(`mx.ntnu.no`), not by our server directly. Port 25 on the current server
isn't reachable from outside, so NTNU's gateway evidently hands omega.ntnu.no
mail on to it internally. That routing is an NTNU IT setting, not a DNS
record - **confirm with NTNU IT** how it's set up, and tell them when the
server or its IP changes.

## The records

### 1. A record for the mail host

```
mail.<domain>.    A    <server-ip>
```

Needed by the MX record (an MX must point at a name with an A record - never
at an IP address or a CNAME) and by the PTR check. Harmless to add early.

### 2. MX - where mail for the domain is delivered

```
<domain>.    MX    10 mail.<domain>.
```

This **replaces** the existing MX. Mail starts arriving at our server as soon
as senders see the new record, so do it last (see "Rollout order").

- The server must accept TCP port 25 from the whole internet. Check from a
  machine **outside** the server's network: `nc -vz mail.<domain> 25`.
- **omega.ntnu.no**: in relay mode keep `mx.ntnu.no` - NTNU's gateway also
  filters spam before it reaches us. Switching the MX to `mail.omega.ntnu.no`
  (needed for direct mode) needs NTNU IT to open inbound port 25 to the server
  in NTNU's firewall, and means our server does its own spam filtering (the
  built-in checks, see README).

### 3. PTR - reverse DNS for the IP

```
<server-ip>  →  PTR  →  mail.<domain>.
```

Requested from the IP owner (**omega.ntnu.no**: NTNU IT). Check with
`dig -x <server-ip> +short`.

An IP has only one PTR, but the test and prod domains share the server.
Point it at **`mail.omega.ntnu.no`** (prod). While the test domain is running,
the PTR still resolves back to the IP (forward-confirmed), which is what
Gmail requires; it just won't match the test server's HELO name
(`mail.<test-domain>`). That's acceptable for testing. Don't change the PTR
back and forth.

### 4. SPF - which IPs may send for the domain

On `<domain>`:

```
<domain>.    TXT    "v=spf1 ip4:<server-ip> -all"
```

**omega.ntnu.no** - keep NTNU's gateways allowed (relay mode, and anything
else NTNU sends as omega.ntnu.no) and add the server:

```
omega.ntnu.no.    TXT    "v=spf1 ip4:<server-ip> redirect=_spfmailgw.ntnu.no"
```

`redirect=` hands over to NTNU's gateway list (which ends in `-all`) if our
IP didn't match.

Rules:

- **Only one SPF record per name.** Two `v=spf1` records = SPF fails
  completely. Merge instead of adding.
- If something else also sends as `@<domain>` (e.g. the website through a
  provider like SMTP2GO in relay mode), add its `include:` to the same record,
  e.g. `v=spf1 ip4:<server-ip> include:spf.smtp2go.com redirect=_spfmailgw.ntnu.no`.
  Every `include`/`redirect` costs DNS lookups, and SPF allows max 10 - keep it short.
- `-all` = "nothing else may send" (hard fail); `~all` = soft fail. With
  DMARC in place, either works; `-all` is the stricter choice.

On the mail host itself - used when receivers check the HELO name, and for
bounces (which have an empty envelope sender, so SPF falls back to the HELO
name):

```
mail.<domain>.    TXT    "v=spf1 a -all"
```

(`a` = "the IP in this name's own A record".)

### 5. DKIM - the signing key

In direct mode the postfix container generates a key on first start and
prints the record to its logs (Dokploy → the app → Logs → postfix):

```
entrypoint: DKIM DNS record (TXT) - publish this, see DNS.md:
entrypoint:   name:  mail._domainkey.<domain>
entrypoint:   value: v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
```

Publish it as:

```
<selector>._domainkey.<domain>.    TXT    "v=DKIM1; k=rsa; p=MIIBIjANBgkq..."
```

- The value is longer than 255 characters (2048-bit key). Some DNS editors
  split it automatically; others need it entered as several quoted strings
  side by side: `"v=DKIM1; k=rsa; p=MIIBIjAN...first-part" "...rest"`. The
  container has it pre-split in BIND format:
  `docker exec <postfix-container> cat /etc/opendkim/keys/<domain>/<selector>.txt`.
- The key lives on the `dkim-keys` volume - **don't delete that volume**, or
  a new key is generated and the published record no longer matches.
- Each domain gets its own key (test and prod), so each needs its own record.
- Rotating (e.g. yearly): set a new `DKIM_SELECTOR` (e.g. `mail2027`) and
  redeploy - a new key is generated and used immediately, so publish its
  record right away (mail signed in the gap fails DKIM, but still passes SPF,
  so DMARC holds). Keep the old record published for a week, then remove it.
- Other senders for the domain (e.g. a provider like SMTP2GO) have their own
  DKIM records under their own selector names - they coexist fine.

### 6. DMARC - the policy

```
_dmarc.<domain>.    TXT    "v=DMARC1; p=none; rua=mailto:dmarc@<domain>"
```

- `p=none` = monitor only: receivers act as before, but send daily aggregate
  reports to the `rua` address. Start here.
- `dmarc@<domain>` must actually receive mail - create it as a mail alias on
  the website pointing at whoever reads the reports. The reports are zipped
  XML; a free DMARC report service (e.g. Postmark's DMARC Digests) turns them
  into a readable weekly summary.
- After 2-4 weeks of reports showing all legitimate mail passing, tighten to
  `p=quarantine` (failing mail goes to spam), then `p=reject` (failing mail
  is refused). This is what stops others from spoofing `@<domain>`.
- Before tightening for **omega.ntnu.no**, check in the reports that *every*
  legitimate sender of `@omega.ntnu.no` mail passes - including anything NTNU
  or other services send as that domain.
- **omega.ntnu.no** has no DMARC record today, so ntnu.no's (`p=none`)
  applies. Publishing our own overrides it for omega.ntnu.no.
- DMARC for *forwarded* mail is judged on the original sender's domain, so
  our policy doesn't affect forwards.

### 7. TLS-RPT - TLS failure reports (optional)

```
_smtp._tls.<domain>.    TXT    "v=TLSRPTv1; rua=mailto:tlsrpt@<domain>"
```

Asks other servers to report when they had TLS problems delivering to us.
Cheap to add; mostly useful together with MTA-STS. Same note about the
address having to exist.

### 8. MTA-STS - not for now

MTA-STS tells other servers "only deliver to my MX over TLS with a valid
certificate". It needs a CA-signed certificate for `mail.<domain>` in
postfix, a policy file served at
`https://mta-sts.<domain>/.well-known/mta-sts.txt`, and a `_mta-sts.<domain>`
TXT record. Our postfix uses a **self-signed** certificate (see README, TLS),
so an enforcing MTA-STS policy would make senders **refuse to deliver**.
It only protects inbound mail against interception, and doesn't affect spam
scoring. If it's ever wanted: get a Let's Encrypt cert for `mail.<domain>`
into postfix first, then publish the policy in `mode: testing` together with
TLS-RPT before switching to `enforce`.

### 9. Not applicable

- **DANE** (TLSA records) - needs DNSSEC, which ntnu.no doesn't have.
- **BIMI** (logo in the inbox) - needs DMARC at quarantine/reject plus a paid
  logo certificate. Not worth it here.

## Beyond DNS

- **Warming up a new IP.** A new sending IP has no reputation, and big
  providers throttle it (Gmail answers `421 4.7.28 ... unusual rate`).
  Postfix just retries later - nothing is lost - but the weekly digest to all
  members is exactly the kind of burst that triggers it. For the first few
  weeks, expect delays on big sends; if possible, start with small volumes.
- **Gmail/Yahoo sender rules** (since 2024). Everyone: SPF or DKIM, valid
  PTR, TLS, spam complaint rate under 0.3%. Bulk senders (5000+ mails a day to
  Gmail): SPF **and** DKIM **and** DMARC, From aligned, and **one-click
  unsubscribe** (`List-Unsubscribe` + `List-Unsubscribe-Post` headers) on
  subscription mail like the digest. The headers are a website-side change.
- **Monitoring**:
  - [Google Postmaster Tools](https://postmaster.google.com) - Gmail's view of
    the domain's reputation and spam rate (verify the domain with a TXT record).
  - [Microsoft SNDS](https://sendersupport.olc.protection.outlook.com/snds/) -
    the same for Outlook/Hotmail, per IP.
  - Blocklist checks: [MXToolbox](https://mxtoolbox.com/blacklists.aspx).
  - The Grafana dashboard's bounce rate - a sudden jump usually means a
    blocklisting or a broken record.
- **Keep spam out.** Every spam message an alias accepts gets forwarded from
  our IP. Direct mode's built-in checks (README) catch the worst. Spamhaus
  only answers queries from the server's own/ISP resolver, not from public
  ones like 8.8.8.8 or 1.1.1.1.

## Rollout order (direct mode)

1. **Ahead of time** (harmless, nothing changes yet):
   - `A mail.<domain>`.
   - Ask for the **PTR** (can take days at NTNU IT).
   - **SPF**: add `ip4:<server-ip>` to the existing record.
   - **DMARC** at `p=none` + create the `dmarc@<domain>` alias.
   - Optionally TLS-RPT.
   - Lower the **MX record's TTL** to 300 seconds, so the switch takes effect
     quickly (and can be undone quickly).
2. Check outbound port 25 from the server (README, "direct mode").
3. Deploy with `DELIVERY_MODE=direct`, publish the **DKIM** record from the
   logs, and check it with `dig` (below).
4. Switch the **MX** to `mail.<domain>` (**omega.ntnu.no**: after NTNU IT has
   opened inbound port 25). Keep the old server running until the old MX's
   TTL has passed.
5. Verify (below), then point the website at postfix (README).
6. After 2-4 weeks of clean DMARC reports: `p=quarantine`, later `p=reject`.
   Raise the MX TTL back to e.g. 3600.

Do it with the test domain first.

## Verifying

DNS (from any machine):

```sh
dig +short A mail.<domain>                      # <server-ip>
dig +short MX <domain>                          # 10 mail.<domain>.
dig +short -x <server-ip>                       # mail.omega.ntnu.no.
dig +short TXT <domain>                         # "v=spf1 ip4:<server-ip> ..."
dig +short TXT mail.<domain>                    # "v=spf1 a -all"
dig +short TXT <selector>._domainkey.<domain>   # "v=DKIM1; k=rsa; p=..."
dig +short TXT _dmarc.<domain>                  # "v=DMARC1; p=none; ..."
```

Port 25 from **outside** the server's network: `nc -vz mail.<domain> 25`
(or MXToolbox's SMTP test).

Real mail:

1. **Forwarding**: create an alias with your own Gmail address as a member,
   then send to the alias from a *different* account (Gmail hides copies of
   your own mail). In Gmail: ⋮ → *Show original*. Expect `SPF: PASS` with
   domain `<domain>` (that's SRS), `DKIM: PASS` for the original sender's
   domain, `DMARC: PASS`.
2. **Website mail**: trigger a notification to yourself. *Show original*:
   `SPF: PASS`, `DKIM: PASS` with `d=<domain>`, `DMARC: PASS`.
3. **Score**: [mail-tester.com](https://www.mail-tester.com) gives a
   throwaway address and grades what arrives (aim for 9-10/10). Make it a
   member of an alias, or have the website send to it. A few tests a day are
   free.
4. **Blocklists**: check `<server-ip>` on MXToolbox.

If something fails, the postfix logs (Dokploy, or `docker logs`) show each
delivery with `status=sent`/`deferred`/`bounced` and the receiving server's
reason.
