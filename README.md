# mail-infrastructure

Mail for Sct. Omega Broderskab: the server that receives mail for the aliases omegaweb-next
manages and forwards it to the members behind them, in the shape that runs in production and in
the shape a developer runs next to omegaweb-next.

```
postfix/   # What runs in production today: Postfix as a Dokploy compose app, with its own docs
dev/       # The mail server for development: Stalwart, with Mailpit as its relay
deploy/    # Later: Stalwart for the cluster, with an overlay per cluster as omegaweb-next has
```

Production is moving from Postfix on Dokploy to Stalwart on the k3s cluster, where
[vivat](https://github.com/vevcom/vivat) names the release of this repo that runs. `dev/` already
runs Stalwart, so omegaweb-next's integration with it can be built before the move.

## How it is consumed

**Production.** Publishing a GitHub release runs `.github/workflows/release.yml`: it builds the
images this repo has, pushes them to GHCR under the release tag, and opens a pull request on vivat
that points its `Application` for this repo at the release, exactly as a release of omegaweb-next
does. Merging that pull request is the deploy. The pull request is opened with the same GitHub App
as omegaweb-next's, so this repo needs the variable `DEPLOY_APP_ID` and the secret
`DEPLOY_APP_PRIVATE_KEY` too.

**Development.** omegaweb-next has this repo as the git submodule `mail-infrastructure/` and
includes `dev/compose.yaml` from it in a compose file of its own, which a developer adds when they
want the mail server. The submodule's commit is the version of the mail server in development,
bumped like any dependency. The application owns how it connects, such as the hostname and the
credentials in its env, and this repo owns what the server is. Dev secrets are dev values written
in `dev/`, never read from the including repo's env.

`dev/` and `deploy/` pin the same Stalwart image, so what runs in development is what runs in
production.
