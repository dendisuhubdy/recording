# summly.xyz Static Site Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the Meeting Recorder landing page and `.dmg` download from summly.xyz on a DigitalOcean droplet, over HTTPS.

**Architecture:** One small droplet running nginx as a static file server, provisioned with Terraform so the infrastructure is reproducible and reviewable. TLS from Let's Encrypt via certbot. Deployment is `rsync` of a static directory — there is no application server, no database, and no runtime.

**Tech Stack:** Terraform, DigitalOcean, Ubuntu 24.04 LTS, nginx, certbot.

**Scope note:** this plan covers only hosting. It deliberately does **not** add an API proxy or an auto-update feed — both were considered and declined, and both would change the app's architecture and privacy story rather than just its distribution. If either becomes wanted, it needs its own spec.

## Global Constraints

- **The DigitalOcean API token is a secret.** It is read from the `DIGITAL_OCEAN_API_TOKEN_PERSONAL` environment variable. It must never be written to a `.tf` file, a `terraform.tfvars`, a shell history file, or any commit.
- **`terraform.tfstate` contains secrets and must never be committed.** It is gitignored in Task 1.
- **Droplet size:** `s-1vcpu-512mb-10gb` (the cheapest tier). This serves static files; anything larger is wasted spend. Revisit only if download traffic actually justifies it.
- **Region:** `sgp1` (Singapore) — closest to the primary user. Change in one variable if that assumption is wrong.
- **Cost is real and recurring.** Do not run `terraform apply` without the account owner's explicit go-ahead.
- **The site is public.** It must not reference the app's Team ID, notarization credentials, or any API key.
- **Commit after every task**, using the message given in that task's final step.

## Prerequisites

Verified 2026-07-25 against the live account:

1. **DigitalOcean API token** — read from `$DIGITAL_OCEAN_API_TOKEN_PERSONAL`.
   Confirmed working (account active, droplet limit 25). ✅
2. **`summly.xyz` is registered** at Namecheap. ✅ Its nameservers point at
   **Cloudflare** (`bill.ns.cloudflare.com`, `rosalie.ns.cloudflare.com`), not
   DigitalOcean — see the DNS note below. This plan keeps Cloudflare.
3. **SSH key** — `~/.ssh/id_ed25519_DO.pub` is already uploaded to DigitalOcean
   under the name **`peptidebay-do`** (verified by matching MD5 fingerprint
   `cf:0f:93:02:ed:43:91:60:7e:ab:8f:21:1a:c1:b7:8d`). ✅ No upload needed;
   the Terraform references that name.

### DNS: Cloudflare stays in front

The original draft of this plan created a `digitalocean_domain` and A records.
That was wrong for this setup: with nameservers at Cloudflare, DigitalOcean DNS
records are never consulted, so those resources would have appeared to succeed
while changing nothing.

Keeping Cloudflare is also the better arrangement — free CDN and DDoS protection
in front of `.dmg` downloads, and no waiting on nameserver propagation. So
Terraform manages **only** the droplet and firewall; the A record is created in
Cloudflare.

**TLS sequencing matters.** Let's Encrypt validates over HTTP against the origin,
so the A record must be **DNS-only (grey cloud)** when the certificate is issued.
After issuance, switching to **proxied (orange cloud)** with SSL mode
**Full (strict)** keeps working and adds the CDN. Doing it in the other order
makes certbot fail against Cloudflare's edge instead of the droplet.

### ⚠️ This is a live, shared account

The account already runs **9 droplets**, including `jenkins-master` and two
Kubernetes nodes. Consequences for anyone executing this plan:

- **Never run `terraform destroy` without reading the plan output first.** This
  Terraform state only manages what it creates, but a mistaken `-target` or a
  state file pointed at the wrong resources is unrecoverable.
- Name everything `summly-*` so it is obvious which droplet belongs to this plan.
- Get explicit confirmation from the account owner before `terraform apply`.

## File Structure

```
site/
  index.html                 # landing page
  style.css
  downloads/                 # .dmg goes here, gitignored
infra/
  main.tf                    # droplet + firewall only (DNS lives in Cloudflare)
  variables.tf
  outputs.tf
  cloud-init.yaml            # nginx install + hardening on first boot
  .gitignore                 # tfstate, .terraform/
scripts/
  deploy-site.sh             # rsync site/ to the droplet
```

---

### Task 1: Landing page

Build the page before the server. It is the part that can be checked locally,
and it costs nothing to iterate on.

**Files:**
- Create: `site/index.html`, `site/style.css`, `site/.gitignore`

**Interfaces:**
- Consumes: nothing
- Produces: a static `site/` directory that Task 4 deploys verbatim

- [ ] **Step 1: Create the download directory guard**

The `.dmg` is a build artifact and must not be committed — it is tens of
megabytes and changes every release.

Create `site/.gitignore`:

```gitignore
downloads/
```

- [ ] **Step 2: Write the landing page**

The privacy disclosure carries over from the README. A meeting recorder that is
vague about where transcripts go is the kind of thing people rightly get angry
about, so it goes on the page itself, not only in the repo.

Create `site/index.html`:

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Meeting Recorder — record and summarize meetings on your Mac</title>
<meta name="description" content="A macOS app with one red button. Records your meeting, transcribes it on-device, and summarizes it with Claude. Open source, GPL-3.0.">
<link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
  <header>
    <div class="dot" aria-hidden="true"></div>
    <h1>Meeting Recorder</h1>
    <p class="tagline">
      One red button. Records your meeting, transcribes it on your Mac,
      and summarizes it with Claude.
    </p>
    <a class="download" href="/downloads/MeetingRecorder.dmg">
      Download for macOS
    </a>
    <p class="requirement">Requires macOS 26 or later · Free and open source</p>
  </header>

  <section>
    <h2>What leaves your computer</h2>
    <table>
      <tr>
        <th>Meeting audio</th>
        <td>Never leaves your Mac. Transcription runs entirely on-device.</td>
      </tr>
      <tr>
        <th>Transcript text</th>
        <td>
          <strong>Sent to the Anthropic API</strong> to generate the summary,
          using your own API key. A transcript contains everything everyone said.
        </td>
      </tr>
      <tr>
        <th>Your API key</th>
        <td>Stored in your macOS Keychain. Nowhere else.</td>
      </tr>
    </table>
    <p>
      There is no backend, no account, no telemetry. Leave the API key blank and
      recording and transcription still work — you just won't get summaries.
    </p>
    <p class="caution">
      In many places it is illegal to record a conversation without the consent
      of everyone in it. This app doesn't check or warn. That part is on you.
    </p>
  </section>

  <section>
    <h2>How it works</h2>
    <p>
      Recording writes your microphone and the system audio to two separate
      files and does no mixing while capture is running — the real-time path
      stays as simple as possible, because that's the one place a bug costs you
      the meeting. Mixing, transcription, and summarizing all happen after you
      press stop, and each can be retried on its own.
    </p>
    <p>Your audio is never deleted automatically.</p>
  </section>

  <footer>
    <a href="https://github.com/OWNER/recording">Source</a> ·
    <a href="https://github.com/OWNER/recording/blob/main/LICENSE">GPL-3.0</a>
  </footer>
</main>
</body>
</html>
```

Replace `OWNER` with the GitHub owner before committing.

- [ ] **Step 3: Write the stylesheet**

Create `site/style.css`:

```css
:root {
  color-scheme: light dark;
  --fg: #16161a;
  --muted: #5b5b66;
  --bg: #fbfbfd;
  --rule: #e3e3e8;
  --accent: #d92d20;
}
@media (prefers-color-scheme: dark) {
  :root { --fg: #ececf1; --muted: #a0a0ab; --bg: #101014; --rule: #2a2a32; }
}

* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font: 17px/1.65 ui-sans-serif, -apple-system, system-ui, sans-serif;
  -webkit-font-smoothing: antialiased;
}
main { max-width: 44rem; margin: 0 auto; padding: 4rem 1.5rem 6rem; }

header { text-align: center; padding-bottom: 3rem; }
.dot {
  width: 76px; height: 76px; border-radius: 50%;
  background: var(--accent); margin: 0 auto 1.75rem;
  box-shadow: 0 6px 28px rgb(217 45 32 / 32%);
}
h1 { font-size: 2.6rem; margin: 0 0 .6rem; letter-spacing: -.022em; }
.tagline { color: var(--muted); font-size: 1.15rem; margin: 0 auto 2rem; max-width: 32rem; }

.download {
  display: inline-block; background: var(--fg); color: var(--bg);
  text-decoration: none; font-weight: 600;
  padding: .8rem 1.9rem; border-radius: 9px;
}
.download:hover { opacity: .88; }
.requirement { color: var(--muted); font-size: .9rem; margin-top: .9rem; }

section { border-top: 1px solid var(--rule); padding-top: 2.25rem; margin-top: 2.25rem; }
h2 { font-size: 1.3rem; margin: 0 0 1rem; letter-spacing: -.012em; }

table { border-collapse: collapse; width: 100%; margin-bottom: 1.25rem; }
th, td { text-align: left; vertical-align: top; padding: .7rem 0; border-bottom: 1px solid var(--rule); }
th { width: 11rem; font-weight: 600; padding-right: 1.25rem; }

.caution { color: var(--muted); font-size: .93rem; border-left: 3px solid var(--accent); padding-left: 1rem; }

footer { border-top: 1px solid var(--rule); margin-top: 3rem; padding-top: 1.5rem; color: var(--muted); font-size: .9rem; text-align: center; }
a { color: inherit; }

@media (max-width: 540px) {
  main { padding-top: 2.5rem; }
  h1 { font-size: 2rem; }
  th { width: auto; display: block; padding-bottom: .2rem; border: 0; }
  td { display: block; padding-top: 0; }
}
```

- [ ] **Step 4: Check it locally**

```bash
cd site && python3 -m http.server 8000
```

Open <http://localhost:8000>:

- [ ] Page renders with the red dot and download button.
- [ ] The "what leaves your computer" table is legible and not cut off.
- [ ] Narrowing the window to phone width keeps the table readable.
- [ ] Toggling System Settings → Appearance to Dark restyles the page.

Stop the server with ⌃C.

- [ ] **Step 5: Commit**

```bash
git add site/
git commit -m "feat: add summly.xyz landing page"
```

---

### Task 2: Terraform infrastructure definition

Writes the definition only. **Nothing is provisioned and nothing is billed
until Task 3.**

**Files:**
- Create: `infra/main.tf`, `infra/variables.tf`, `infra/outputs.tf`, `infra/cloud-init.yaml`, `infra/.gitignore`

**Interfaces:**
- Consumes: prerequisites (token, domain, SSH key)
- Produces: droplet IP as a Terraform output, consumed by Task 4's deploy script

- [ ] **Step 1: Guard the state file**

`terraform.tfstate` records resource attributes in plaintext and must never be
committed.

Create `infra/.gitignore`:

```gitignore
.terraform/
.terraform.lock.hcl
terraform.tfstate
terraform.tfstate.backup
*.tfvars
```

- [ ] **Step 2: Declare the variables**

Create `infra/variables.tf`:

```hcl
variable "do_token" {
  description = "DigitalOcean API token. Set via TF_VAR_do_token, never in a file."
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Apex domain served by this droplet."
  type        = string
  default     = "summly.xyz"
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "sgp1"
}

variable "size" {
  description = "Droplet size. This serves static files; the smallest tier is sufficient."
  type        = string
  default     = "s-1vcpu-512mb-10gb"
}

variable "ssh_key_name" {
  description = <<-EOT
    Name of the SSH key already uploaded to DigitalOcean. Defaults to
    "peptidebay-do", which is the account's name for the key whose private half
    is at ~/.ssh/id_ed25519_DO (verified by fingerprint).
  EOT
  type        = string
  default     = "peptidebay-do"
}

variable "acme_email" {
  description = "Contact address for Let's Encrypt expiry notices."
  type        = string
}
```

- [ ] **Step 3: Write the server bootstrap**

Create `infra/cloud-init.yaml`. This runs once on first boot.

```yaml
#cloud-config
package_update: true
package_upgrade: true

packages:
  - nginx
  - certbot
  - python3-certbot-nginx
  - ufw
  - rsync

write_files:
  - path: /etc/nginx/sites-available/summly
    content: |
      server {
          listen 80;
          listen [::]:80;
          server_name summly.xyz www.summly.xyz;
          root /var/www/summly;
          index index.html;

          # Serve the DMG as a download rather than letting the browser guess.
          location /downloads/ {
              types { application/x-apple-diskimage dmg; }
              add_header Content-Disposition "attachment";
          }

          location / {
              try_files $uri $uri/ =404;
          }

          add_header X-Content-Type-Options "nosniff" always;
          add_header Referrer-Policy "strict-origin-when-cross-origin" always;
      }

runcommand_marker: &deploy
  - rm -f /etc/nginx/sites-enabled/default
  - ln -sf /etc/nginx/sites-available/summly /etc/nginx/sites-enabled/summly
  - mkdir -p /var/www/summly/downloads
  - chown -R www-data:www-data /var/www/summly
  - ufw allow OpenSSH
  - ufw allow "Nginx Full"
  - ufw --force enable
  - nginx -t && systemctl reload nginx

runcmd: *deploy
```

- [ ] **Step 4: Write the infrastructure**

Create `infra/main.tf`:

```hcl
terraform {
  required_version = ">= 1.6"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.40"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

data "digitalocean_ssh_key" "deploy" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "web" {
  name      = "summly-web"
  image     = "ubuntu-24-04-x64"
  region    = var.region
  size      = var.size
  ssh_keys  = [data.digitalocean_ssh_key.deploy.id]
  user_data = file("${path.module}/cloud-init.yaml")

  # Static files are redeployed by rsync, so the droplet holds no unique state.
  # Losing it costs a `terraform apply`, not data.
  backups    = false
  monitoring = true
}

resource "digitalocean_firewall" "web" {
  name        = "summly-web"
  droplet_ids = [digitalocean_droplet.web.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Egress is needed for apt and Let's Encrypt.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

// No DNS resources here on purpose. summly.xyz uses Cloudflare nameservers, so
// DigitalOcean DNS records would never be consulted — creating them would look
// like it worked while doing nothing. The A record is created in Cloudflare;
// see the DNS section of this plan.
```

Create `infra/outputs.tf`:

```hcl
output "droplet_ip" {
  description = "Public IPv4 address. Used by scripts/deploy-site.sh."
  value       = digitalocean_droplet.web.ipv4_address
}

output "ssh_command" {
  description = "Convenience command for logging in."
  value       = "ssh -i ~/.ssh/id_ed25519_DO root@${digitalocean_droplet.web.ipv4_address}"
}
```

- [ ] **Step 5: Validate without provisioning**

`validate` and `fmt` do not contact DigitalOcean and cost nothing.

```bash
cd infra
terraform init
terraform fmt -check
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add infra/
git commit -m "feat: add Terraform definition for summly.xyz droplet"
```

---

### Task 3: Provision the droplet

**This task spends money.** It creates a billable droplet. Get the account
owner's explicit go-ahead before Step 2.

**Files:** none — this task runs commands.

**Interfaces:**
- Consumes: `infra/` from Task 2
- Produces: a running droplet with TLS; its IP feeds Task 4

- [ ] **Step 1: Review the plan output**

```bash
cd infra
export TF_VAR_do_token="$DIGITAL_OCEAN_API_TOKEN_PERSONAL"
export TF_VAR_acme_email="<your email>"
terraform plan
```

Expected: `Plan: 2 to add, 0 to change, 0 to destroy` — the droplet and the
firewall, nothing else. **Read the output.** If it proposes destroying or
changing anything, stop immediately: this account runs 9 unrelated droplets and
Terraform should be touching none of them.

- [ ] **Step 2: Apply**

```bash
terraform apply
```

Type `yes` only after confirming the plan. Expected: `Apply complete! Resources: 5 added.`
Note the `droplet_ip` output.

- [ ] **Step 3: Wait for cloud-init to finish**

The droplet answers SSH before it has finished installing nginx. Poll rather
than guessing:

```bash
IP=$(terraform output -raw droplet_ip)
ssh -i ~/.ssh/id_ed25519_DO -o StrictHostKeyChecking=accept-new root@"$IP" \
  'cloud-init status --wait'
```

Expected: `status: done`. This takes 2–4 minutes on first boot.

- [ ] **Step 4: Add the A record in Cloudflare, DNS-only**

In the Cloudflare dashboard for `summly.xyz` → **DNS** → **Add record**:

| Field | Value |
|---|---|
| Type | `A` |
| Name | `@` |
| IPv4 address | the `droplet_ip` from Step 2 |
| Proxy status | **DNS only (grey cloud)** — for now |
| TTL | Auto |

Add a second identical record with Name `www`.

**Grey cloud matters here.** Let's Encrypt validates over HTTP against the
origin; with the orange cloud on, certbot's challenge hits Cloudflare's edge
instead of the droplet and fails. Step 7 turns the proxy on afterwards.

Confirm it resolves to the droplet before continuing:

```bash
dig +short summly.xyz
dig +short www.summly.xyz
```

Expected: both print the droplet IP. Cloudflare DNS propagates in seconds, not
hours — if it is still empty after a minute, re-check the record. **Do not run
Step 5 until this resolves**; repeated Let's Encrypt failures hit rate limits.

- [ ] **Step 5: Issue the TLS certificate**

```bash
ssh -i ~/.ssh/id_ed25519_DO root@"$IP" \
  "certbot --nginx -d summly.xyz -d www.summly.xyz \
     --non-interactive --agree-tos -m '$TF_VAR_acme_email' --redirect"
```

Expected: `Successfully received certificate`. The `--redirect` flag makes
certbot rewrite the nginx config to force HTTPS.

- [ ] **Step 6: Verify the renewal timer is active**

A certificate that silently fails to renew takes the site down in 90 days.

```bash
ssh -i ~/.ssh/id_ed25519_DO root@"$IP" \
  'systemctl is-active certbot.timer && certbot renew --dry-run'
```

Expected: `active`, then `Congratulations, all simulated renewals succeeded`.

- [ ] **Step 7: Turn on the Cloudflare proxy**

Now that a real certificate is on the origin, switch both A records to
**Proxied (orange cloud)**, and set **SSL/TLS → Overview → Full (strict)**.

Full (strict) verifies the origin certificate, which is exactly what Step 5
installed. Do not use **Flexible**: it makes Cloudflare talk to the origin over
plain HTTP while showing visitors a padlock, which is worse than no TLS because
it looks secure and isn't.

- [ ] **Step 8: Verify the server responds**

```bash
curl -sI https://summly.xyz | head -1
curl -sI http://summly.xyz | head -1
curl -sI https://summly.xyz | grep -i "^server:"
```

Expected: `HTTP/2 404` from HTTPS (nginx is up; no `index.html` deployed yet —
Task 4 fixes that), `HTTP/1.1 301` from HTTP proving the redirect works, and a
`server: cloudflare` header confirming the proxy is active.

- [ ] **Step 9: Record the outcome**

No commit — nothing changed in the repo. Note the droplet IP where the team can
find it, and confirm `git status` in `infra/` shows no `terraform.tfstate`.

```bash
git status --short infra/
```

Expected: no output.

---

### Task 4: Deploy the site and the DMG

**Files:**
- Create: `scripts/deploy-site.sh`

**Interfaces:**
- Consumes: `site/` (Task 1), the running droplet (Task 3), `dist/MeetingRecorder.dmg` (main plan Task 14)
- Produces: a live site

- [ ] **Step 1: Write the deploy script**

Create `scripts/deploy-site.sh`:

```bash
#!/usr/bin/env bash
# Deploy the static site (and the DMG, if built) to the summly.xyz droplet.
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_DO}"
REMOTE_ROOT="/var/www/summly"
DMG="dist/MeetingRecorder.dmg"

IP="${DROPLET_IP:-$(cd infra && terraform output -raw droplet_ip 2>/dev/null || true)}"
if [[ -z "$IP" ]]; then
  echo "error: no droplet IP. Set DROPLET_IP, or run from a tree with infra/ state." >&2
  exit 1
fi

echo "==> Deploying site/ to $IP"
# --delete keeps the server matching the repo, but downloads/ is excluded so a
# site deploy never removes an already-published DMG.
rsync -az --delete --exclude 'downloads/' \
  -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
  site/ root@"$IP":"$REMOTE_ROOT"/

if [[ -f "$DMG" ]]; then
  echo "==> Uploading $(basename "$DMG") ($(du -h "$DMG" | cut -f1))"
  rsync -az --progress -e "ssh -i $SSH_KEY" \
    "$DMG" root@"$IP":"$REMOTE_ROOT"/downloads/
else
  echo "==> No $DMG found — skipping. Run ./scripts/release.sh first to publish a build."
fi

ssh -i "$SSH_KEY" root@"$IP" "chown -R www-data:www-data $REMOTE_ROOT"

echo "==> Live: https://summly.xyz"
```

```bash
chmod +x scripts/deploy-site.sh
```

- [ ] **Step 2: Deploy**

```bash
./scripts/deploy-site.sh
```

Expected: rsync transfers `index.html` and `style.css`; the DMG step reports
either an upload or a clear skip message.

- [ ] **Step 3: Verify the live site**

```bash
curl -sI https://summly.xyz | head -1
curl -s https://summly.xyz | grep -c "Meeting Recorder"
```

Expected: `HTTP/2 200`, and a non-zero grep count.

In a browser at <https://summly.xyz>:

- [ ] The page renders with a valid certificate (no browser warning).
- [ ] `http://summly.xyz` redirects to HTTPS.
- [ ] `https://www.summly.xyz` also serves the page.
- [ ] If a DMG was uploaded, clicking Download downloads it, and the downloaded
      file opens without a Gatekeeper warning — this is the real end-to-end
      test of main-plan Task 14.

- [ ] **Step 4: Commit**

```bash
git add scripts/deploy-site.sh
git commit -m "feat: add site deploy script"
```

---

## Verification checklist

- [ ] `cd infra && terraform validate` passes
- [ ] `https://summly.xyz` serves the landing page with a valid certificate
- [ ] `http://summly.xyz` redirects to HTTPS
- [ ] `certbot renew --dry-run` succeeds on the droplet
- [ ] The DMG downloads and opens with no Gatekeeper warning
- [ ] `git status` shows no `terraform.tfstate`, no `*.tfvars`, no `.dmg`
- [ ] `git grep -I "dop_v1_" -- ':!docs/**'` returns nothing — no DO token committed
      (the trailing underscore and the `docs/**` exclusion keep this from matching
      its own text here, so a pass actually means something)

## Teardown

To stop billing entirely:

```bash
cd infra && terraform destroy
```

This deletes the droplet, firewall, and DNS records. The site goes offline and
the DNS records are removed, so point the registrar elsewhere first if the
domain is still wanted.
