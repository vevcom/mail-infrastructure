# mail-infrastructure

Mail for Sct. Omega Broderskab: [Stalwart](https://stalw.art), which receives mail for the aliases
omegaweb-next manages and forwards it to the members behind them, and the
[Bulwark](https://bulwarkmail.org) webmail for reading the mailboxes on it. In the shape that runs
on the cluster, and in the shape a developer runs next to omegaweb-next.

```
deploy/base/   # Stalwart and Bulwark for Kubernetes: the generic shape, which vivat's overlay fills in
dev/           # The same server for development, with Mailpit as its relay, as a compose file
postfix/       # What ran before: Postfix on Dokploy. Deleted once the cluster receives the mail
```

Nothing here names a domain, a certificate or a password. Those belong to whoever runs an
installation; ours is [vivat](https://github.com/vevcom/vivat), which deploys `deploy/base` for
omega.ntnu.no and says there how the move from Postfix goes.

## What deploy/base is

- **Stalwart**, one instance with its data on a volume, its admin password from the `mail-env`
  secret the overlay provides, and the mail ports on the node's address. HTTP, which is the admin
  ui, the management api and JMAP, goes through the ingress.
- **Bulwark**, whose browsers talk to Stalwart's JMAP api at the address in `bulwark-config`.
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
address, since the application sends as its aliases. Mailboxes people log in to with their
omegaweb-next account come later, once omegaweb-next can act as an OpenID Connect provider.

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
