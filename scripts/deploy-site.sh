#!/usr/bin/env bash
# Deploy the static site (and the DMG, if built) to the summly.xyz droplet.
#
# Requires SSH access to the droplet. The droplet accepts the key DigitalOcean
# calls "peptidebay-do", whose private half is ~/.ssh/id_ed25519_DO and is
# passphrase-protected — load it once with:
#     ssh-add --apple-use-keychain ~/.ssh/id_ed25519_DO
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_DO}"
REMOTE_ROOT="/var/www/summly"
DMG="dist/MeetingRecorder.dmg"

IP="${DROPLET_IP:-$(cd infra && terraform output -raw droplet_ip 2>/dev/null || true)}"
if [[ -z "$IP" ]]; then
  echo "error: no droplet IP. Set DROPLET_IP, or run from a tree with infra/ state." >&2
  exit 1
fi

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new)

if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 "root@$IP" true 2>/dev/null; then
  echo "error: cannot authenticate to root@$IP." >&2
  echo "       If $SSH_KEY is passphrase-protected, run: ssh-add $SSH_KEY" >&2
  exit 1
fi

echo "==> Deploying site/ to $IP"
# --delete keeps the server matching the repo, but downloads/ is excluded so a
# site deploy never removes an already-published DMG.
rsync -az --delete --exclude 'downloads/' \
  -e "ssh ${SSH_OPTS[*]}" \
  site/ "root@$IP:$REMOTE_ROOT/"

if [[ -f "$DMG" ]]; then
  echo "==> Uploading $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"
  rsync -az --progress -e "ssh ${SSH_OPTS[*]}" \
    "$DMG" "root@$IP:$REMOTE_ROOT/downloads/"
else
  echo "==> No $DMG found — skipping. Run ./scripts/release.sh first to publish a build."
fi

ssh "${SSH_OPTS[@]}" "root@$IP" "chown -R www-data:www-data $REMOTE_ROOT"

echo "==> Live: https://summly.xyz"
