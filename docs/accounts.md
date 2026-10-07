# Accounts and configuration

This page is the one-time account setup that comes before the server (phase 1). Everything is done in browsers, mostly on the iPad. Menu names follow the consoles as of autumn 2026 and may have moved; use the search box of the console if a menu is not where it says. Nothing here needs the server yet. Replace values in `<angle brackets>`.

Where a step needs a value that only the owner knows (a team name, a domain, a date), it is a placeholder. A line starting `TODO(owner)` is a value you write down here once you have it.

## Do this first

1. Install Blink Shell, Tailscale, ntfy and GitHub on the iPad.
2. Make an SSH key in Blink and keep the public line for Hetzner:

   ```bash
   ssh-keygen -t ed25519 -C "ipad-blink"
   cat ~/.ssh/id_ed25519.pub
   ```

3. Do the sections below in this order: Hetzner, Tailscale, Cloudflare, GitHub.
4. Go on with [server.md](server.md).

## Who owns what

Three places, kept apart on purpose:

| | Personal account `andras-tkcs` | Org `privacyfence` |
|---|---|---|
| Owns | the repositories `nightshift` and `nightshift-sandbox` | only PrivacyFence (`privacyfence/privacyfence`) |
| Nightshift plugins | the marketplace lives in `nightshift` | never referenced; installed at user scope on ns-main |
| Project files in the repo | none | `.claude/project-profile.yaml`, skills and `ns-github.env` are facts about PrivacyFence and live there |
| Agent token | resource owner `andras-tkcs`, with Workflows | resource owner `privacyfence`, without Workflows |
| Admin token for `ns-gh` (7 days) | one, resource owner `andras-tkcs` | one, resource owner `privacyfence` |

The org never learns that Nightshift exists, apart from the project's own `.claude/` files. Nothing Nightshift-specific goes into the org: no plugin reference, no Nightshift repository, no org-level token.

All tokens are created from your user account (a token is always created by a person). One fine-grained token covers one owner's repositories only. That is why there are two agent tokens and two admin tokens, and why `ns` picks the token by the project's owner.

Which token lives where on ns-main:

| Token | Lives in | Used by |
|---|---|---|
| Agent token for `andras-tkcs` (the default owner) | `gh auth login` on ns-main (`gh`'s own store) | `ns`, the agents |
| Agent token for another owner such as `privacyfence` | `~/.config/ns/tokens/<owner>`, mode 600, one line | `ns`, for projects of that owner |
| Admin tokens | never stored: typed into `GH_TOKEN` for one `ns-gh` run, as root | `ns-gh audit` and `ns-gh apply` |

## Hetzner

At console.hetzner.com:

1. Create an account and add a payment method.
2. Project `nightshift`: Security, SSH keys, add the Blink public key.
3. Same project: Firewalls, create `ns-fw` with inbound TCP 22 from anywhere (temporary; you delete it at the end of [server.md](server.md)) and UDP 41641 (Tailscale direct connections).
4. Project `nightshift-lab` for throwaway test servers: Security, API tokens, a Read and Write token. Keep it for `bootstrap.sh` (step 6); it can only see this project.
5. Optional, only if you move the QA runner: project `privacyfence-qa`.

## Tailscale

At login.tailscale.com:

1. Sign up with GitHub or Google. The free Personal plan is enough.
2. Sign in to the Tailscale app on the iPad with the same account, allow the VPN profile and turn on Use Tailscale DNS.
3. DNS: keep MagicDNS on; under HTTPS Certificates choose Enable HTTPS. Note the tailnet name (`<tailnet>.ts.net`).
4. Access controls: replace the whole policy with the following and save. Servers get tags, so your devices can reach them but ns-main cannot reach other servers such as a QA runner. Tagged servers never need key renewal.

   ```json
   {
     "tagOwners": {
       "tag:ns-main": ["autogroup:admin"],
       "tag:qa":      ["autogroup:admin"]
     },
     "grants": [
       { "src": ["autogroup:member"], "dst": ["tag:ns-main", "tag:qa"], "ip": ["*"] }
     ],
     "ssh": [
       { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:ns-main"], "users": ["ns", "root"] },
       { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:qa"],      "users": ["root", "runner"] }
     ]
   }
   ```

TODO(owner): record the tailnet name (`<tailnet>.ts.net`) here once you have it.

## Cloudflare: Zero Trust and who may log in

At dash.cloudflare.com. Here you only decide who may get in and protect the addresses. The tunnel that connects ns-main is made in [setup.md](setup.md), so nothing is ever reachable before it is protected.

### 1. Create the Zero Trust organization

1. Dashboard home, Zero Trust in the left sidebar.
2. Choose a team name. It becomes `<team>.cloudflareaccess.com`, the address of your login page, and is hard to change later.
3. Choose the Zero Trust Free plan. Cloudflare asks for payment details even for the free plan.

### 2. Login method: Google

Login methods live under Zero Trust, Integrations, Identity providers. No Google API needs enabling: Cloudflare's plain Google provider only uses Google sign-in.

In the Google Cloud console (console.cloud.google.com):

1. Create a new project, for example `nightshift-access`. Keep it separate from PrivacyFence's connector projects, so their OAuth settings never mix.
2. APIs and Services, OAuth consent screen (newer consoles: Google Auth Platform), Get started: app name `Nightshift`, your support email, audience External, your contact email, accept the policy, Create.
3. Data access / scopes: add nothing. The basic `openid`, `email` and `profile` scopes need no verification.
4. Audience: leave the publishing status at Testing and add your own Google address under Test users. Only listed test users can sign in, which is what you want.
5. Clients, Create client (older consoles: Credentials, Create credentials, OAuth client ID): type Web application, name `Cloudflare Access`.
   - Authorized JavaScript origins: `https://<team>.cloudflareaccess.com`
   - Authorized redirect URIs: `https://<team>.cloudflareaccess.com/cdn-cgi/access/callback`
6. Create, then copy the Client ID and the Client secret. Do not paste them anywhere but Cloudflare.

In Cloudflare:

1. Zero Trust, Integrations, Identity providers, Add new identity provider, Google.
2. Paste the Client ID into App ID and the secret into Client secret. Turn on Proof Key for Code Exchange (PKCE). Save.
3. In the list choose Test next to Google and sign in. The success page lists your email: that exact address goes into the policy below.
4. Leave the Cloudflare entry in place as a fallback, but do not enable it on the applications.

Two-factor comes from your Google account, so make sure it is on there. If the test fails with `redirect_uri_mismatch`, the team name in the two Google URLs differs from your Zero Trust team name. If it fails with "access blocked", the address you sign in with is not on the test-user list.

### 3. One reusable policy: "only me"

1. Zero Trust, Access controls, Policies, Add a policy.
2. Name `only me`, action Allow, session duration 24 hours.
3. Under Include, selector Emails, value: the Google address the test showed. Nothing under Require or Exclude.
4. Save. Every application below uses this one policy, so changing who may log in later is one edit.

### 4. Protect the two desk addresses

1. Zero Trust, Access controls, Applications, Create new application, Self-hosted and private.
2. Add public hostname: subdomain `ns-desk`, domain: yours. Use exactly one level under the domain (`ns-desk.<domain>`, not `desk.ns.<domain>`): the free certificate covers `*.<domain>` only.
3. Application name `Nightshift desk`; session duration 24 hours.
4. Policies: Select existing policies, `only me`.
5. Login methods: only Google. With a single method, turn on Apply instant authentication.
6. Save. Repeat for `ns-view` (name `Nightshift reports`).
7. Let SilverBullet's static client files through. The browser fetches the desk's service worker script without following a login redirect, so behind Access alone it fails with "The script resource is behind a redirect, which is disallowed" whenever the Access session is missing or expired. SilverBullet's own [authentication proxy notes](https://docs.silverbullet.md/Authentication%20Proxy) name the two paths to exclude:
   1. Access controls, Policies, Add a policy: name `public static`, action Bypass, Include selector Everyone. Save.
   2. Applications, Create new application, Self-hosted and private, name `Nightshift desk static`. Add public hostname `ns-desk`, your domain, path `service_worker.js`; add a second public hostname `ns-desk`, your domain, path `.client/*`.
   3. Policies: Select existing policies, `public static` only. Save. Access applies the application with the more specific path, so these two paths skip the login while the rest of `ns-desk` stays behind `only me`.

   These paths serve only SilverBullet's own client code, which is public anyway; pages, `/.fs/*` and the API stay behind the login. `ns-view` has no service worker and needs no bypass.

Each application has to match the address of its tunnel route in [setup.md](setup.md) exactly. Access applications are deny-by-default, so an address protected here stays closed even before anything runs behind it.

### 5. A terminal on the work laptop: pick one

- Option A, Tailscale SSH Console (recommended, nothing to set up here): in the browser, login.tailscale.com, Machines, ns-main, the three dots, SSH. Try it once from the work network. If it connects, skip option B.
- Option B, Cloudflare's browser terminal, if the work network blocks Tailscale:
  1. A third application as in part 4: subdomain `ns-ssh`, name `Nightshift terminal`, policy `only me`.
  2. Open it, Configure, turn on Allow access through browser-based RDP, SSH, or VNC sessions, choose SSH, save.
  3. Zero Trust, Access controls, Service credentials, SSH, Add a certificate, select the `Nightshift terminal` application and copy the public key it shows. `bootstrap.sh` step 5 asks for it.

### 6. Leave DNS alone

No DNS records yet. The tunnel routes in [setup.md](setup.md) create them. Never add an A record that points at ns-main's IP address.

## GitHub

At github.com. See "Who owns what" above for the split.

### Your user account

1. Settings, Password and authentication: two-factor on, ideally with a passkey.
2. Settings, Emails: turn on Keep my email addresses private and Block command line pushes that expose my email. The server's commits use the noreply address shown there.
3. Install the GitHub app on the iPad, to approve waiting QA jobs later.

### Personal account: the Nightshift repositories

1. Create `nightshift` (with a README) and an empty `nightshift-sandbox` under `andras-tkcs`.
2. Decide public or private. Branch rulesets on private repositories are only enforced with GitHub Pro. Nightshift holds no secrets, so public is the simplest: the rules work for free and the plugin installs without a token. If it is private, either take GitHub Pro or accept that `main` is not protected from the agents' token.
3. In each of the two repositories: Settings, Rules, Rulesets, New branch ruleset. Target the default branch, enforcement Active, turn on Restrict deletions, Block force pushes and Require a pull request before merging with 0 required approvals. `ns-gh` keeps these in line later.
4. Create the agent token for `andras-tkcs`: your profile, Settings, Developer settings, Personal access tokens, Fine-grained tokens, Generate new token.
   - Name `ns-main dev`, resource owner `andras-tkcs`, expiry 90 days (set a calendar reminder).
   - Repository access: only select repositories, `nightshift` and `nightshift-sandbox`.
   - Permissions: Contents, Issues, Pull requests, Actions and Workflows read and write; Commit statuses read.
5. [server.md](server.md) uses this token for `gh auth login`.

### Org privacyfence

1. Org, Settings, Authentication security: require two-factor for members.
2. Org, Settings, Personal access tokens, Settings: under fine-grained tokens choose Allow access via fine-grained personal access tokens. If you also turn on "Require administrator approval", approve your own requests under Pending requests.
3. The PrivacyFence agent token is created later, from your user account as above: resource owner `privacyfence`, only `privacyfence/privacyfence`, Contents, Issues, Pull requests and Actions read and write, Commit statuses read. No Workflows, Administration, Secrets or Environments. It goes into `~/.config/ns/tokens/privacyfence` on ns-main (mode 600).
4. The two admin tokens (one per owner, 7 days, Administration, Environments and Issues write) are created only on the evening you run `ns-gh`, see [security.md](security.md).

The environments for live QA (`live-qa`) exist only in the PrivacyFence repository. QA test credentials never go on ns-main.
