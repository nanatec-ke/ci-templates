#!/usr/bin/env bash
# Prepare a target server for PM2 deploys driven by ci-templates/deploy-pm2.yml.
#
# Run this ONCE per app, per server, as the deploy user (the same user whose
# public key is in ~/.ssh/authorized_keys and whose private key is stored in the
# repo's DEPLOY_SSH_KEY secret). It is idempotent — safe to re-run.
#
#   Usage:  ./server-bootstrap.sh <deploy_path>
#   Example: ./server-bootstrap.sh /opt/azil/frontend/AZIL-FRONTEND
#
# It creates the release layout, seeds an empty shared/.env (fill it in after),
# and makes sure PM2 is installed and set to resurrect on boot.

set -euo pipefail

BASE="${1:?Usage: server-bootstrap.sh <deploy_path>}"

echo "==> Creating release layout under $BASE"
mkdir -p "$BASE/releases" "$BASE/shared"

if [ ! -f "$BASE/shared/.env" ]; then
  echo "==> Seeding empty $BASE/shared/.env (edit this with real values)"
  touch "$BASE/shared/.env"
  chmod 600 "$BASE/shared/.env"
else
  echo "==> $BASE/shared/.env already present, leaving it alone"
fi

echo "==> Checking Node / PM2"
if ! command -v node >/dev/null 2>&1; then
  echo "!! node is not installed. Install Node (>=20) before deploying — PM2 runs the app with node." >&2
fi
if ! command -v pm2 >/dev/null 2>&1; then
  if command -v npm >/dev/null 2>&1; then
    echo "==> Installing PM2 globally"
    npm install -g pm2
  else
    echo "!! pm2 not found and npm unavailable to install it. Install PM2 manually: npm i -g pm2" >&2
  fi
fi

if command -v pm2 >/dev/null 2>&1; then
  echo "==> Configuring PM2 to resurrect saved processes on reboot"
  echo "    If this prints a 'sudo env ... pm2 startup' command, run it once as root:"
  pm2 startup || true
  pm2 save || true
fi

cat <<DONE

==> Done.

Layout ready:
  $BASE/
  ├── shared/.env        <-- put this app's runtime + build env here
  ├── releases/          <-- deploy-pm2.yml writes releases/<sha> here
  └── current -> ...      (created on first deploy)

Next:
  1. Fill in $BASE/shared/.env with the real values (PUBLIC_* are read at BUILD
     time by Astro, so they must be correct here before the first deploy).
  2. Make sure the deploy user owns $BASE and runs the PM2 daemon.
  3. Point nginx at the app's PM2 port(s) (see each repo's nginx.conf).
  4. Add the repo's DEPLOY_* secrets in GitHub (see ci-templates/README.md).
DONE
