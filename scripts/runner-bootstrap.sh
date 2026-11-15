#!/usr/bin/env bash
# Install the tools the CI/CD workflows need on a self-hosted runner HOST.
#
# Run ONCE per runner machine, as root (or with sudo). Idempotent — safe to
# re-run, e.g. after re-provisioning the runner. This is the permanent fix for
# "Unable to locate executable file: unzip" and the same class of
# missing-tool errors (rsync, sshpass, ssh).
#
#   sudo ./runner-bootstrap.sh
#
# Why each package:
#   unzip           oven-sh/setup-bun downloads Bun as a .zip and extracts it
#   rsync           deploy-pm2.yml ships each release to the server with rsync
#   openssh-client  ssh/scp used by the deploy
#   sshpass         only needed if any environment uses auth_method: password
#   curl, tar, git, ca-certificates   checkout/build basics

set -euo pipefail

PKGS="unzip rsync openssh-client sshpass curl ca-certificates tar git"

echo "==> Installing runner prerequisites: $PKGS"
if   command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y $PKGS
elif command -v dnf     >/dev/null 2>&1; then dnf install -y $PKGS
elif command -v yum     >/dev/null 2>&1; then yum install -y $PKGS
elif command -v apk     >/dev/null 2>&1; then apk add --no-cache $PKGS
elif command -v zypper  >/dev/null 2>&1; then zypper install -y $PKGS
else
  echo "!! No supported package manager found. Install manually: $PKGS" >&2
  exit 1
fi

echo
echo "==> Verifying:"
missing=0
for b in unzip rsync ssh scp sshpass curl tar git; do
  path="$(command -v "$b" 2>/dev/null || true)"
  printf '  %-8s %s\n' "$b" "${path:-MISSING}"
  [ -n "$path" ] || missing=1
done

echo
if [ "$missing" -eq 0 ]; then
  echo "==> All prerequisites present. The runner is ready for ci-node + deploy-pm2."
else
  echo "!! Some tools are still missing — install them before running the pipeline." >&2
  exit 1
fi

cat <<'NOTE'

Note: `node` and `pm2` are NOT needed on the runner — they run on the deploy
*servers* (see server-bootstrap.sh). The runner only builds and ships.
NOTE
