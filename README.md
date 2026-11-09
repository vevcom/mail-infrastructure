# mail-infrastructure

Mail for Sct. Omega Broderskab: [Stalwart](https://stalw.art), which receives mail for the aliases
omegaweb-next manages and forwards it to the members behind them, and the
[Bulwark](https://bulwarkmail.org) webmail for reading the mailboxes on it. In the shape that runs
on the cluster, and in the shape a developer runs next to omegaweb-next.

```
deploy/base/   # Stalwart and Bulwark for Kubernetes: the generic shape, which vivat's overlay fills in
dev/           # The same server for development, with Mailpit as its relay, as a compose file
postfix/       # Postfix on Dokploy, which receives the mail until the cluster does. Deleted then
```

Nothing here names a domain, a certificate or a password. Those belong to whoever runs an
installation; ours is [vivat](https://github.com/vevcom/vivat), which deploys `deploy/base` for
omega.ntnu.no and says there how the move from Postfix goes.

## What deploy/base is

- **Stalwart**, one instance with its data on a volume, its admin password from the `mail-env`
  secret the overlay provides, and the mail ports on the node's address. HTTP, which is the admin
  ui, the management api and JMAP, goes through the ingress.
- **Bulwark**, whose browsers talk to Stalwart's JMAP api at the address in `bulwark-config`, and
  whose users sign in through the application's OpenID Connect provider, see
  [How users sign in](#how-users-sign-in).
- **The provision job**, which applies the plans in `stalwart-plan` on every sync and reloads the
  settings. `plan.ndjson` here is the base plan: logging to standard output and the HTTP settings.
  The overlay merges its own plan in as `20-site.ndjson` with the domain, the hostname, the relay
  and the certificate, and appends an init container to the job that applies it.
- **A weekly certificate reload**, for a certificate the overlay has cert-manager write to the
  `stalwart-tls` secret, which Stalwart reads from files.

A plan is NDJSON for `stalwart-cli apply`: every line an `upsert` keyed on the object's name, an
`update` of a singleton or a `reconcile`, so it converges and is applied on every sync.

## What the application does

Stalwart does not read the alias tables the way Postfix did. omegaweb-next talks to the management
api instead, as the admin: it creates a mailing list per alias with the members as recipients, and
its own account, which it sends mail through. The overlay's plan lets that account send as any
address, since the application sends as its aliases.

Every alias also keeps its mail in a mailbox, unless its owners switch that off: a group account
on the webmail's host as a domain, which the alias's list delivers to besides forwarding, and which
the people who receive the alias's mail see as a shared folder in the webmail. The application
creates and removes those groups. Who is a member of which it never writes to the server: it is in
the `groups` claim of the token a user signs in to the webmail with, and Stalwart makes the user a
member of exactly those groups at every sign in.

## How users sign in

Stalwart authenticates against the application, which is an OpenID Connect provider on the domain
its config marks as the auth domain. The overlay's plan defines the directory and makes it the one
authentication uses, with the issuer and the webmail's host filled in:

```
{"@type":"upsert","object":"Directory","matchOn":["description"],"value":{"omegaweb":{"@type":"Oidc","description":"omegaweb-next signs users in","issuerUrl":"https://<auth host>","claimUsername":"preferred_username","usernameDomain":"<webmail host>","claimName":"name","claimGroups":"groups","acceptedAudiences":["<webmail host>"]}}}
{"@type":"update","object":"Authentication","value":{"directoryId":"#omegaweb"}}
```

The claims are the contract with the application: `preferred_username` is the account, `groups`
the mailboxes it may open, and the webmail's host is the client the application issues tokens to,
the audience it names and the domain the mailboxes and the accounts are on, so the one host goes
in `usernameDomain`, `acceptedAudiences`, `OAUTH_CLIENT_ID` and the application's
`EMAIL_WEBMAIL_URL` alike. `OAUTH_ISSUER_URL` in `bulwark-config` is the same issuer. The
webmail asks the provider for the mail scope on its own, since the provider lists it.

An account is made the first time someone signs in. The mailbox domain has to exist by then: the
application creates it with the mailboxes, so a server where the application has not synced yet
turns the first sign in away.

Once the directory is active, Stalwart sends every password login to it, and the provider has no
passwords: a mail client or the webmail signing in with a password is refused. App passwords are
the exception, which Stalwart checks itself before asking the directory, and the recovery admin
keeps its own. The application's sending account is affected like any other: how it authenticates
is the application's business, see its README, and a plain password no longer does.

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
