# mail-infrastructure

Mail for Sct. Omega Broderskab: [Stalwart](https://stalw.art), which receives mail for the addresses
omegaweb-next manages, those of its aliases and of its users, and forwards it to the people behind
them, and the [Bulwark](https://bulwarkmail.org) webmail for reading the mailboxes on it. In the
shape that runs on the cluster, and in the shape a developer runs next to omegaweb-next.

```
deploy/base/   # Stalwart and Bulwark for Kubernetes: the generic shape, which vivat's overlay fills in
dev/           # The same server for development, with Mailpit as its relay, as a compose file
```

Nothing here names a domain, a certificate or a password. Those belong to whoever runs an
installation; ours is [vivat](https://github.com/vevcom/vivat), which deploys `deploy/base` for
omega.ntnu.no.

## What deploy/base is

- **Stalwart**, one instance with its data on a volume, its admin password from the `mail-env`
  secret the overlay provides, and the mail ports on the node's address. HTTP, which is the admin
  ui, the management api and JMAP, goes through the ingress.
- **Bulwark**, whose browsers talk to Stalwart's JMAP api at the address in `bulwark-config`, and
  whose users sign in through the application's OpenID Connect provider, see
  [How users sign in](#how-users-sign-in).
- **The provision job**, which applies the plans in `stalwart-plan` on every sync and reloads the
  settings. `plan.ndjson` here is the base plan: logging to standard output, the HTTP settings and
  the listener the application sends its mail through, see
  [How the application sends](#how-the-application-sends).
  The overlay merges its own plan in as `20-site.ndjson` with the domain, the hostname, the relay
  and the certificate, and appends an init container to the job that applies it.
- **A weekly certificate reload**, for a certificate the overlay has cert-manager write to the
  `stalwart-tls` secret, which Stalwart reads from files.

A plan is NDJSON for `stalwart-cli apply`: every line an `upsert` keyed on the object's name, an
`update` of a singleton or a `reconcile`, so it converges and is applied on every sync.

## What the application does

omegaweb-next talks to Stalwart's management api, as the admin, and puts every address it has
there: those of its aliases, and the one each user has, which is their username on Omega's main
domain until a user admin moves it. Without a webmail every address is a mailing list: an alias's
with the members as recipients, and a user's with their private email. The application has no
account of its own.

With a webmail, every address keeps its mail in a mailbox. An alias's is a group account at the
alias's own address, which the people who receive the alias's mail see as a shared folder in the
webmail, under the alias's name, and answer as. A user's is the account they sign in to, at their
own address, see [How users sign in](#how-users-sign-in). The application makes it ahead of their
first sign in, so mail to the address has somewhere to arrive, and moves it when the address
changes, so the mail stays.

An address is a mailbox or a mailing list on the server, not both, so a mailbox sends the mail on
itself, with a script that keeps the mail and sends a copy on. A user's mailbox sends it to their
private email. An alias's sends it to a list of the alias's members on `forward.<webmail host>`, a
domain for those lists alone, which needs no DNS. Whether an address forwards is
set in the application, by the user for their own address and by the owners for an alias: with it
off the mailbox only keeps the mail, and a user's runs no script of the application's, so one of
their own may run. While it is on, the application's script is the one that runs.

The application creates and removes the accounts, the groups, the lists and the scripts, and it
writes who is a member of which mailbox: every minute it makes the account of each user a member of
the mailboxes of the aliases they receive, and of no other. The account of a user who is deleted in
the application is destroyed, with its mail. The account of an archived user is left where it is,
and sends nothing on.

## Whose the domains are

The application creates the mail domains of its sites, which its `sites.json` lists, so a new site
with mail needs no line in a plan. The two domains the mailboxes take are not a site's, and the
application creates neither. They are the overlay's plan's, as upserts next to the server's own
domain: the webmail's host, for the names users are signed in by, and `forward.<webmail host>`, for
the lists the mailboxes forward to.

```
{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"forward":{"name":"forward.<webmail host>","description":"..."}}}
```

The application looks those two up by name. While the server lacks one it leaves every address as
it was, and says so in its log every minute.

## How users sign in

Stalwart authenticates against the application, which is an OpenID Connect provider on the domain
its config marks as the auth domain. The overlay's plan defines the directory and makes it the one
authentication uses, with the issuer and the webmail's host filled in:

```
{"@type":"upsert","object":"Directory","matchOn":["description"],"value":{"omegaweb":{"@type":"Oidc","description":"omegaweb-next signs users in","issuerUrl":"https://<auth host>","claimUsername":"preferred_username","usernameDomain":"<webmail host>","claimName":"name","claimGroups":null,"acceptedAudiences":{"<webmail host>":true}}}}
{"@type":"update","object":"Authentication","value":{"directoryId":"#omegaweb"}}
```

The token only says who signed in. Stalwart builds the name it signs them in by from
`preferred_username` and `usernameDomain`, such as `kari@<webmail host>`, and signs them in to the
account that has that address, as its own or as an alias. That is how a user's account can be at
the address they have in the application: the application keeps the sign in name as an alias of
the account, and the address itself is the application's to move. So the sign in name is never an
address anyone writes to, and the webmail's host needs no MX record.

No claim names groups, and `claimGroups` is null so that Stalwart reads none: with one it rewrites
a user's memberships from the token at every sign in, and the memberships are the application's to
keep. The webmail's host is the client the application issues tokens to, the audience it names and
the domain of the sign in names, so the one host goes in `usernameDomain`, `acceptedAudiences`,
`OAUTH_CLIENT_ID` and the application's `EMAIL_WEBMAIL_URL` alike. `OAUTH_ISSUER_URL` in
`bulwark-config` is the same issuer. The webmail asks the provider for the mail scope on its own,
since the provider lists it, and Stalwart refuses a token without that scope.

The application makes a user's account ahead of their first sign in. Someone who signs in before
it has, a user created within the last minute, is given an account by Stalwart at their sign in
name, which the application then moves to their address. The domain of the sign in names is in the
overlay's plan, so it is there by then. A new account sees its mailboxes once the application has
synced again, within the minute.

Once the directory is active, Stalwart hands every login to it, and it only takes the provider's
tokens: a mail client or the webmail signing in with a password is refused. App passwords are the
exception, which Stalwart checks itself before asking the directory, and the recovery admin keeps
its own. `acceptedAudiences` is a set, so it is written as an object with the host as key: Stalwart
refuses a list there, and with it the whole directory.

## What someone signed in sends as

Stalwart lets someone signed in send as the addresses that are theirs: their own, and those of the
mailboxes they are a member of. It checks the envelope sender alone, so a member of a mailbox
could still write any address in the From header. The base plan closes that with the system script
`from-header`, which the DATA stage runs on every mail from someone signed in: it refuses a mail
whose From header is not the address the mail is sent as. So a member answers as the mailbox they
answer from and as no one else. What the application sends is not signed in and is left alone.

The mailboxes forward to lists on `forward.<webmail host>`, and a list takes mail from anyone. The
copies a mailbox sends on never pass the RCPT stage, so nothing else has to reach those lists. The
base plan holds the script `refuse-recipient`, which refuses the recipient it is run for, and the
overlay's plan runs it for that domain when the sender is not signed in:

```
{"@type":"update","object":"MtaStageRcpt","value":{"script":{"match":{"0":{"if":"is_empty(authenticated_as) && rcpt_domain == 'forward.<webmail host>'","then":"'refuse-recipient'"}},"else":"false"}}}
```

A script is only run when it is active, `isActive` true, which it is not unless the plan says so.
Both rules take effect on the reload that ends the overlay's plan, with no restart.

## How the application sends

The application sends as its aliases, to anyone, and it is not a person the directory could sign
in. So it has no account and no password. The base plan gives Stalwart a listener of its own for
it, `application` on port 2525, and four rules that go by that port:

- no login is asked for there,
- mail for any domain is relayed from there,
- mail from a domain the server hosts is DKIM signed there, as it is for someone signed in,
- and the spam filter, which is for mail coming in, leaves it alone.

What reaches that port may send as any address, so who reaches it is the whole of its security.
It is SMTP with STARTTLS on the `stalwart` service inside the cluster, and never on
`stalwart-public`. The certificate is for the server's public name and not the service's, so the
application is told that name to verify it by, `EMAIL_TLS_SERVERNAME` in omegaweb-next. An
overlay has to keep everything but the application away from it, with a NetworkPolicy; ours is in
vivat. In development it is only on the compose network.

Stalwart opens a listener when it starts, not when its settings are reloaded. The first time the
base plan is applied to a server, the listener exists but nothing answers on 2525 until Stalwart
has been restarted once: `kubectl rollout restart statefulset/stalwart` in the overlay's
namespace, or `docker compose restart stalwart` in development.

## How it is consumed

**Production.** Publishing a GitHub release runs `.github/workflows/release.yml`, which opens a
pull request on vivat that points its mail overlay at the release. Merging that pull request is the
deploy. The pull request is opened with the same GitHub App as omegaweb-next's, so this repo needs
the variable `DEPLOY_APP_ID` and the secret `DEPLOY_APP_PRIVATE_KEY` too.

**Development.** omegaweb-next has this repo as the git submodule `mail-infrastructure/` and
includes `dev/compose.yaml` from it in a compose file of its own, which a developer adds when they
want the mail server. The submodule's commit is the version of the mail server in development,
bumped like any dependency. The application owns how it connects, such as the hostname and the
credentials in its env, and this repo owns what the server is. Dev secrets are dev values written
in `dev/`, never read from the including repo's env.

`dev/` mounts `deploy/base/config.json` and applies `deploy/base/plan.ndjson` before its own, and
both pin the same images, so what runs in development is what runs in production.
