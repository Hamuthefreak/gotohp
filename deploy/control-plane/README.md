# gotohp relay control plane

A public dashboard for a private backup relay. Sign in with Freebuff, change
every upload setting, run the relay on demand, and see what it is doing.

The relay runs on a 1 GB Oracle Always Free instance. That box has no domain, no
certificate and no business accepting inbound connections, so it never does:

```
browser ──▶ dashboard (Cloudflare Worker + D1)
                    ▲
                    │  the VM asks, every minute
                    │  (device token, outbound only)
              relay VM ──▶ Google Photos
```

The VM pulls settings and commands from the Worker and reports state back. No
port is opened on the instance, no TLS has to be terminated there, and the
Worker holds nothing worth stealing except the settings.

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

Changing a setting writes one key in D1. The agent picks it up within a minute,
rewrites `/etc/gotohp-sync/config.env` in place, and restarts the timer only if
the schedule actually changed.

## Login and ownership

Sign-in is Freebuff's. The **first account to open the dashboard claims it**;
every other account gets 403 from then on. That is deliberate: the relay has one
operator, and a claimed dashboard cannot be taken over by whoever finds the URL.
Settings, state and the device token all live behind that check, on the server,
not in the browser.

The device token is shown once and stored only as a SHA-256 hash. Rotating it
invalidates the old one immediately.

## Adding a control

1. Add a field to `src/schema.js` (type, range, default, help).
2. Read it in `deploy/oracle-free-tier/sync.sh` and pass the matching gotohp flag.
3. Add a check for it in `deploy/oracle-free-tier/test-sync.sh`.

The form, the API validation and the agent's own validation all come from step 1.

## Develop

```sh
npm install
npm run build        # dist/worker.js + dist/public
npm run dev          # http://localhost:8787, local D1, development client ID
```

The development client ID in `wrangler.jsonc` is public and only valid for
`http://localhost:8787`. `ALLOW_INSECURE_LOCALHOST=1` exists only there; a
deployed environment is https and never sets it.

## Deploy

`deploy.json` is the Sites manifest. Deployment also injects
`FREEBUFF_CLIENT_ID`, `FREEBUFF_ISSUER` and `APP_ORIGIN`, and attaches the `DB`
D1 database. There is no secret to set on the Worker: the client ID and origin
are public configuration.

## Pair the VM

1. Sign in, then **Generate device token**.
2. Add two repository secrets: `CONTROL_URL` (this dashboard's origin) and
   `CONTROL_DEVICE_TOKEN` (the token).
3. Re-run the deploy workflow. It writes the URL into the config and the token to
   `/etc/gotohp-sync/device.token`, both root-only.

Until both exist the agent is dormant and exits immediately.

## What this deliberately does not do

- It cannot read your Google session or the SSH key; neither passes through it.
- It cannot exfiltrate your media. The only data reported is counts, disk usage,
  timer state and the last run summary.
- It is not a file browser. Watermelon stays the source of truth for the library.
