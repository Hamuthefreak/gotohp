# gotohp relay control plane

A public dashboard for a private backup relay. Sign in with Google, change every
upload setting, run the relay on demand, and watch what it is doing **while it
runs**.

The relay runs on a 1 GB Oracle Always Free instance. That box has no domain, no
certificate and no business accepting inbound connections, so it never does:

```
browser ──▶ dashboard (Worker + D1, or Vercel function + Blob)
                    ▲
                    │  the VM asks, every 20 seconds
                    │  (device token, outbound only)
              relay VM ──▶ Google Photos
```

The VM pulls settings and commands from the dashboard and pushes back what it is
doing. No port is opened on the instance, no TLS has to be terminated there, and
the dashboard holds nothing worth stealing except the settings.

## Two hosts, one app

`src/app.js` is the whole HTTP surface, written against Web `Request`/`Response`,
and both hosts mount it unchanged:

| Host | Entry | Sign-in | Storage |
| --- | --- | --- | --- |
| Cloudflare Worker (Freebuff Sites) | `src/worker.js` | Sign in with Freebuff | D1 (`src/store-d1.js`) |
| Vercel functions | `api/**` | Sign in with Google | Blob (`src/store-blob.js`) |

Blob reads use `useCache: false`, so a dashboard that polls every few seconds
never sees a version cached for up to a minute.

## Live activity

The relay used to report only its last finished run, which made the dashboard a
photograph. Now every run leaves a small JSON file behind:

```json
{ "phase": "uploading", "total": 312, "uploaded": 47, "current": "2024/07/IMG_0421.HEIC",
  "batch": 2, "batches": 4, "started_at": "...", "exit": null }
```

`sync.sh` rewrites it as the run moves (scanning → uploading → idle, or error),
and `control-agent.sh` ships it plus the last six lines of the CLI log every 20
seconds. The Worker keeps the last few dozen transitions as a feed, so the page
can show "Uploading 47 of 312 · now: IMG_0421.HEIC · batch 2/4" and a scrolling
history instead of a stale counter.

Polling is 20 seconds, not realtime: it costs two tiny HTTP calls per tick and
survives the box going away for a while. The page itself refreshes every four
seconds and pauses while the tab is hidden.

## What it can change

Every column of the relay's behaviour, from `src/schema.js`:

| Group | Controls |
| --- | --- |
| Schedule | pause/resume, run interval, files per batch |
| Upload | threads, storage saver, quota counting, force re-upload, date from filename, type filter, excluded directories, album (or `AUTO` per folder), account |
| Live photos | pairing, unpaired halves, upgrade existing photos, match by filename |
| Disk | delete after upload, dry run |
| Advanced | log level |

Plus actions: **Run now**, **Re-scan files**, **Refresh state**.

Changing a setting writes one key. The agent picks it up within 20 seconds,
rewrites `/etc/gotohp-sync/config.env` in place, and restarts the timer only if
the schedule actually changed.

## Login and ownership

The Vercel deployment signs in with **one password** (`DASHBOARD_PASSWORD`), kept
for 30 days in a signed `HttpOnly` cookie. That is enough for a dashboard that
controls one person's relay and does not need an identity provider. The Sites
deployment keeps Freebuff sign-in.

The **first account to open the Sites dashboard claims it**; every other account
gets 403 from then on. Settings, live activity and the device token all live
behind that check, on the server, never in the browser.

The device token is shown once and stored only as a SHA-256 hash.

## Google Photos accounts

gotohp does not use a normal OAuth consent flow: it exchanges the `oauth_token`
cookie from <https://accounts.google.com/EmbeddedSetup> for a Photos credential.
That cookie is not readable from another site, so the dashboard cannot capture
it for you - but it can carry it to the relay, which is the part that used to
mean editing a repository secret.

1. **Sign in with Google** opens Embedded Setup in a new tab.
2. Sign in as the account you want the photos in, then copy the `oauth_token`
   cookie's value.
3. Paste it into the dashboard. It is queued, delivered to the VM exactly once,
   applied with `gotohp-cli creds add -` as the sync user, and then deleted from
   the control plane.

The card then lists every account on the box, from `gotohp-cli creds list`.
**Use this** runs `creds set`, so switching where uploads land is one click;
**Remove** runs `creds remove`. Photos already uploaded stay where they are.

## Vercel deployment

Already provisioned: project `gotohp-relay`, a private Blob store `gotohp-live`
(bound as `BLOB_READ_WRITE_TOKEN`), and the environment variables `APP_ORIGIN`,
`AUTH_SECRET`, `DASHBOARD_PASSWORD`.

To change the password later, edit `DASHBOARD_PASSWORD` in the Vercel project
(Settings → Environment Variables) and redeploy. Existing cookies stay valid
until they expire; `AUTH_SECRET` is what signs them.

Deploy from this directory:

```sh
npx vercel deploy --prod
```

## Cloudflare (Freebuff Sites) deployment

`deploy.json` is the Sites manifest. Deployment injects `FREEBUFF_CLIENT_ID`,
`FREEBUFF_ISSUER` and `APP_ORIGIN`, and attaches the `DB` D1 database. There is
no secret to set on the Worker: the client ID and origin are public
configuration.

## Adding a control

1. Add a field to `src/schema.js` (type, range, default, help).
2. Read it in `deploy/oracle-free-tier/sync.sh` and pass the matching gotohp flag.
3. Add a check for it in `deploy/oracle-free-tier/test-sync.sh`.

The form, the API validation and the agent's own validation all come from step 1.

## Develop

```sh
npm install
npm test             # route tests for src/app.js, no runtime needed
npm run build        # dist/worker.js + dist/public, for Sites
npm run dev          # http://localhost:8787, local D1, development client ID
```

The development client ID in `wrangler.jsonc` is public and only valid for
`http://localhost:8787`.

## Pair the VM

1. Sign in, then **Generate device token**.
2. Add two repository secrets: `CONTROL_URL` (this dashboard's origin) and
   `CONTROL_DEVICE_TOKEN` (the token).
3. Re-run the deploy workflow. It writes the URL into the config and the token to
   `/etc/gotohp-sync/device.token`, both root-only.

Until both exist the agent is dormant and exits immediately.

## What this deliberately does not do

- It cannot read your Google session or the SSH key; neither passes through it.
- It cannot exfiltrate your media. What it reports is counts, disk usage, timer
  state, the current filename and the tail of the uploader's own log.
- It is not a file browser. Watermelon stays the source of truth for the library.
