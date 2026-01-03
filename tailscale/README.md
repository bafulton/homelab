# Tailscale ACL GitOps

Tailscale ACLs are managed via GitOps. The web editor is locked.

## How it works

1. Edit `policy.hujson` and open a PR
2. GitHub Actions tests the ACL changes
3. On merge, the ACL is applied to the tailnet

## Authentication

Uses [workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation) - GitHub's OIDC token is exchanged for a short-lived Tailscale API token. No static secrets stored in GitHub.

## Setup

### 1. Configure Tailscale workload identity

Go to [Tailscale Admin → Settings → Trust credentials](https://login.tailscale.com/admin/settings/trust):

1. Click **New credential** → **OpenID Connect**
2. Issuer: **GitHub**
3. Subject: `repo:<owner>/<repo>:*` (e.g., `repo:bafulton/homelab:*`)
4. Scopes: Select **policy_file** (read + write)
5. Save and note the **Client ID** and **Audience**

### 2. Add GitHub variables

Go to repo **Settings → Variables → Actions** and add:

| Variable | Description |
|----------|-------------|
| `TS_CLIENT_ID` | Client ID from step 1 |
| `TS_AUDIENCE` | Audience from step 1 |
| `TS_TAILNET` | Your tailnet name (e.g., `catfish-mountain.ts.net`) |

These are not secrets - the security comes from GitHub's signed OIDC tokens.

### 3. Export initial policy

Download your current ACL from [Admin Console → Access Controls](https://login.tailscale.com/admin/acls) and save as `policy.hujson`.

### 4. Lock the web editor

Go to [Admin Console → Settings → General](https://login.tailscale.com/admin/settings/general), scroll to **Policy file management**, and select **GitOps** or **Locked**.

## Resources

- [Tailscale ACL documentation](https://tailscale.com/kb/1018/acls)
- [Tailscale GitOps with GitHub Actions](https://tailscale.com/kb/1306/gitops-acls-github)
- [Workload identity federation](https://tailscale.com/kb/1581/workload-identity-federation)
- [HuJSON format](https://github.com/tailscale/hujson)
