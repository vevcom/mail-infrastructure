# infra

The services Sct. Omega Broderskab runs that have no repo of their own, laid out so that the
same service can run in production and on a developer's machine from one definition.

```
services/
└── mail/
    ├── postfix/   # The Postfix that receives mail for the aliases today, deployed with Dokploy
    └── dev/       # The mail server for development: Stalwart with Mailpit as its relay
```

Each service is a directory under `services/`. A service has up to three halves:

- `k8s/`: the manifests for the cluster, with an overlay per cluster, as omegaweb-next has in its
  `deploy/`. [vivat](https://github.com/vevcom/vivat) names the release of this repo its
  `Application` for the service runs.
- `dev/`: a compose file an application repo includes to run the service on a developer's machine,
  with the same image as the cluster runs and nothing that leaves the machine.
- Anything else the service needs before it has a `k8s/` half, such as `mail/postfix/` today.

The two halves of a service pin the same image tag, so what runs in development is what runs in
production.

## How it is consumed

**Production.** Publishing a GitHub release of this repo runs `.github/workflows/release.yml`: it
builds the images of the services that have one, pushes them to GHCR under the release tag, and
opens a pull request on vivat that points its `Application`s for this repo at the release, exactly
as a release of omegaweb-next does. Merging that pull request is the deploy. The pull request is
opened with the same GitHub App as omegaweb-next's, so this repo needs the variable `DEPLOY_APP_ID`
and the secret `DEPLOY_APP_PRIVATE_KEY` too.

**Development.** An application repo adds this repo as a git submodule and includes a service's
`dev/compose.yaml` in its own compose file:

```yaml
include:
    - path: infra/services/mail/dev/compose.yaml
      project_directory: infra/services/mail/dev
```

The submodule's commit is the version of every dev half at once. The application owns how it
connects to the service, such as the hostname and credentials in its env, and this repo owns what
the service is. A dev half declares its services under a compose profile named after the service,
so it only starts when asked for: `docker compose --profile mail up`.

## Adding a service

1. Make `services/<name>/`, with `dev/compose.yaml` and, once it runs in the cluster, `k8s/`.
2. Name every compose service and volume so it cannot collide with an application's own, and put
   them under the `<name>` profile.
3. Dev secrets are dev values written in the dev half, never read from the including repo's env.
   Production secrets come from Phase through the `k8s/` half.
4. Pin image tags in both halves to the same version.
