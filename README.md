# ci-templates

Reusable GitHub Actions workflows for building and deploying the Nanatec
frontends. One set of templates drives CI/CD for every repo, so each app repo
carries a ~20-line caller workflow instead of its own bespoke pipeline.

**Primary deploy method: PM2.** Apps are Astro SSR (Node standalone) servers run
under PM2 on their own hosts. A single shared self-hosted runner builds each app
and ships the release to the app's server over SSH.

---

## Contents

- [`ci-node.yml`](.github/workflows/ci-node.yml) — install, format-check, typecheck, build. No secrets. For PRs and pre-deploy validation.
- [`deploy-pm2.yml`](.github/workflows/deploy-pm2.yml) — build on the runner, ship over SSH, reload PM2. **The main deploy template.**
- [`deploy-docker.yml`](.github/workflows/deploy-docker.yml) — alternative for repos that ship a container.
- [`scripts/server-bootstrap.sh`](scripts/server-bootstrap.sh) — prepares a server's release layout, run once per app/host.

---

## Deployment plan (the big picture)

### Topology

```
      GitHub (orgs: nanatec-ke, nana-tec)
                │  on: push to main/develop
                ▼
   ┌──────────────────────────────┐
   │   Shared self-hosted runner   │   (registered in a separate org / at the
   │   labels: self-hosted, linux  │    enterprise level; shared to both orgs)
   │                               │
   │   1. checkout                 │
   │   2. install + build (bun)    │
   │   3. rsync release over SSH   │
   └───────────────┬──────────────┘
          SSH / rsync (per environment)
         ┌──────────┴───────────┐
         ▼                      ▼
  ┌───────────────┐      ┌───────────────┐
  │  cush server  │      │  azil server  │   each repo → its own host
  │  PM2: 4 procs │      │  PM2: 1 proc  │
  │  nginx 80→4325…│      │  nginx 80→4321│
  └───────────────┘      └───────────────┘
```

The runner never hosts an app. It is a build-and-ship box: it compiles the app
and pushes the artifact to whichever server owns that environment. Adding a new
app or a new server does **not** require touching the runner.

### Release model (atomic + rollbackable)

Each server gets a Capistrano-style layout under the repo's `deploy_path`:

```
<deploy_path>/
├── shared/.env          # server-owned runtime + build env; never shipped, never overwritten
├── releases/<sha>/      # one immutable dir per deploy
└── current -> releases/<sha>
```

A deploy: rsync the new build into `releases/<sha>`, install prod deps there,
flip the `current` symlink, `pm2 startOrReload current/ecosystem.config.cjs`,
then prune old releases. Rollback = re-point `current` at a previous release and
reload (see [Rollback](#rollback)).

### End-to-end flow

1. Push to `main` (production) or `develop` (staging), or open a PR.
2. **PRs** run `ci-node.yml` only — install, checks, build. Nothing is deployed.
3. **Pushes** run `ci-node.yml`, then `deploy-pm2.yml` gated on the matching
   GitHub Environment.
4. `deploy-pm2.yml`:
   - fetches the build-time `.env` (from the server's `shared/.env` by default —
     important because Astro **inlines every `PUBLIC_*` at build time**),
   - `bun install` + `bun run build` on the runner,
   - rsyncs the release to `releases/<sha>` on the target server,
   - installs production deps on the server, flips `current`, reloads PM2, prunes,
   - optionally health-checks a URL.

---

## Cross-org sharing & the shared runner (read this first)

Two facts about this setup need deliberate configuration:

**1. The templates live in `nanatec-ke`, but `AZIL-FRONTEND` lives in `nana-tec`.**
A private repo's reusable workflows can only be called from *another* org if you
either (a) are on GitHub Enterprise and allow org/enterprise sharing, or (b) make
the templates repo **public**. `ci-templates` holds no secrets — only workflow
YAML — so **making `nanatec-ke/ci-templates` public is the simplest fix** and
lets both orgs consume it. (Within `nanatec-ke`, cush can call it once you set
*Settings → Actions → General → Access → Accessible from repositories owned by
nanatec-ke*.)

**2. "The same runner, in a different organization."**
A single self-hosted runner can only be *shared* across orgs when it is
registered at the **enterprise level** and exposed through a runner group granted
to both orgs (GitHub Enterprise Cloud). If you are not on Enterprise, you cannot
truly share one registration across two orgs — instead register the runner once
per org (the same machine can run multiple runner services side by side) and give
them the **same labels** (`self-hosted`, `linux`). The templates key off labels,
not registration, so either approach works with no workflow change.

> Recommended: consolidate `nana-tec` and `nanatec-ke` under one enterprise (or
> one org) so a single enterprise runner group serves everything and the
> templates repo can stay private.

---

## Secrets & GitHub Environments

Deploys are gated on **GitHub Environments** (`production`, `staging`). Create
them per repo (*Settings → Environments*) and attach the secrets there, so prod
and staging can point at different servers and prod can require approval.

Per environment, set:

| Secret | What it is |
| --- | --- |
| `DEPLOY_HOST` | Target server hostname/IP for this environment |
| `DEPLOY_USER` | SSH user that owns `deploy_path` and the PM2 daemon |
| `DEPLOY_SSH_KEY` | Private key authorised for `DEPLOY_USER` (key auth) |
| `DEPLOY_PASSWORD` | SSH password (only if `auth_method: password`) |
| `DEPLOY_KNOWN_HOSTS` | Output of `ssh-keyscan <host>` (pins the host key; always required) |
| `BUILD_DOTENV` | *(optional)* full `.env`, only if `dotenv_source: secret` |

By default (`dotenv_source: server`) the build env is pulled from the server's
`shared/.env`, so you do **not** need `BUILD_DOTENV` and the server stays the
single source of truth for env.

Generate a deploy key and pin the host:

```bash
ssh-keygen -t ed25519 -f deploy_key -C "gha-deploy" -N ""
ssh-copy-id -i deploy_key.pub  <user>@<host>     # or append deploy_key.pub to authorized_keys
ssh-keyscan <host>                               # paste into DEPLOY_KNOWN_HOSTS
#   deploy_key        -> DEPLOY_SSH_KEY
#   deploy_key.pub    -> server's ~/.ssh/authorized_keys
```

Enable *production → Required reviewers* if you want a manual gate before prod.

### Servers that only allow password auth

`ssh`/`scp`/`rsync` can't take a password from a flag or env var on their own, so
the template uses [`sshpass`](https://linux.die.net/man/1/sshpass) when you set
`auth_method: password`. For such a server:

1. Install `sshpass` on the self-hosted runner once: `sudo apt-get install -y sshpass`.
2. Add a `DEPLOY_PASSWORD` secret (instead of `DEPLOY_SSH_KEY`) to that environment.
3. In the caller, pass `auth_method: password`. `DEPLOY_KNOWN_HOSTS` is still
   required — the host key is pinned regardless of auth method.

```yaml
    with:
      app_name: azil-frontend
      environment: production
      deploy_path: /opt/azil/frontend/AZIL-FRONTEND
      auth_method: password
    secrets: inherit
```

The password is passed to `sshpass -e` via the `SSHPASS` env var, so it never
appears on a command line (`ps` can't see it) or in the logs (Actions masks the
secret). Auth method can differ per environment with an expression, e.g.
`auth_method: ${{ github.ref_name == 'main' && 'key' || 'password' }}`.

> **Strongly prefer keys.** A password grants a full interactive shell, can't be
> scoped with a forced command, is awkward to rotate, and needs `sshpass` on the
> runner. If you can SSH in even once, bootstrap a key and never use the password
> again:
>
> ```bash
> ssh-keygen -t ed25519 -f deploy_key -N ""
> ssh-copy-id -i deploy_key.pub <user>@<host>   # prompts for the password this one time
> # then store deploy_key as DEPLOY_SSH_KEY and use auth_method: key
> ```

---

## Onboarding a repo (checklist)

1. **Server:** run [`scripts/server-bootstrap.sh <deploy_path>`](scripts/server-bootstrap.sh)
   as the deploy user, then fill in `<deploy_path>/shared/.env`.
2. **Secrets:** add the `DEPLOY_*` secrets to the repo's `production` (and
   `staging`) Environments.
3. **nginx:** point it at the app's PM2 port(s) — each repo has an `nginx.conf`.
4. **Workflow:** add `.github/workflows/ci-cd.yml` that calls the templates (see
   the two live examples below).
5. **Pin a version:** callers reference `@v1`; tag the templates repo (below).

### Versioning the templates

Callers pin `@v1`. Cut that tag and move it forward on compatible changes:

```bash
git tag -f v1 && git push -f origin v1     # moving the v1 pointer
# breaking change -> introduce v2 and migrate callers deliberately
```

---

## Caller examples (live)

**Monorepo, Bun + Turbo (cush, 4 Astro apps):**

```yaml
jobs:
  ci:
    uses: nanatec-ke/ci-templates/.github/workflows/ci-node.yml@v1
    with: { package_manager: bun, build_command: "bun run build" }
  deploy:
    if: github.event_name == 'push'
    needs: ci
    uses: nanatec-ke/ci-templates/.github/workflows/deploy-pm2.yml@v1
    with:
      app_name: cush-frontend
      environment: ${{ github.ref_name == 'main' && 'production' || 'staging' }}
      package_manager: bun
      deploy_path: /opt/cush/cush-frontend
    secrets: inherit
```

The full files are in each repo at `.github/workflows/ci-cd.yml`.

---

## `deploy-pm2.yml` inputs

| Input | Default | Notes |
| --- | --- | --- |
| `app_name` | — (required) | Release dir / PM2 namespace label |
| `environment` | — (required) | GitHub Environment to deploy to |
| `deploy_path` | — (required) | Base dir on the server, e.g. `/opt/azil/frontend/AZIL-FRONTEND` |
| `package_manager` | `bun` | `bun` or `npm` |
| `build_command` | `"<pm> run build"` | Override for monorepo/custom builds |
| `node_version` | `22` | Used when `package_manager=npm` |
| `bun_version` | `1.2.13` | Used when `package_manager=bun` |
| `runs_on` | `["self-hosted","linux"]` | Runner label selector (JSON array) |
| `dotenv_source` | `server` | `server` (scp `shared/.env`) \| `secret` (`BUILD_DOTENV`) \| `none` |
| `auth_method` | `key` | `key` (`DEPLOY_SSH_KEY`) \| `password` (`DEPLOY_PASSWORD` via sshpass) |
| `keep_releases` | `5` | Releases retained on the server for rollback |
| `health_url` | `""` | Optional post-deploy curl; non-2xx fails the deploy |

---

## Rollback

List releases and re-point `current` on the server, then reload:

```bash
cd /opt/<app>
ls -1dt releases/*/              # newest first; pick the known-good <sha>
ln -sfn "releases/<good-sha>" current
cd current && PM2_HOME=$HOME/.pm2 pm2 startOrReload ecosystem.config.cjs --env production
```

Because old releases are kept (`keep_releases`), rollback is a symlink flip — no
rebuild. To roll forward, just re-run the deploy on the good commit.

---

## Notes & limits

- Astro **inlines `PUBLIC_*` at build time** — changing them requires a rebuild,
  not just a PM2 restart. Keep them correct in `shared/.env` before deploying.
- PM2 processes run in `fork` mode (single HTTP server per app); `startOrReload`
  drains in-flight requests (`kill_timeout`) but is not true zero-downtime.
- The SSH private key is written to `$RUNNER_TEMP/ssh` and removed in an
  `always()` step, so it never lingers on the persistent runner.
- `rsync --delete` makes each release an exact copy of the build; the
  server-owned `shared/.env` is excluded and symlinked in, never overwritten.
