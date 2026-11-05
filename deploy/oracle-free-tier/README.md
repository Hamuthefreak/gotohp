# Watermelon Backup -> gotohp -> Google Photos on Oracle Always Free

**Step-by-step setup, from creating the Oracle account: [SETUP.md](SETUP.md).**

> Day-to-day control, including every upload setting and a **Run now**
> button, is in the [control dashboard](../control-plane/README.md). The relay
> works without it; it is not required.

## The short answer

Yes, this works - but not the way the question was phrased. **gotohp is not a
server.** It has no listen, receive, or watch mode: it walks a directory that is
already on disk and pushes those files to Google Photos. Nothing in this repo
accepts a connection from a phone.

So the free VM has to be the thing Watermelon already knows how to talk to:

```
iPhone (Watermelon Backup, SFTP node)
        |
        |  SFTP, originals, /YYYY/MM/original-filename
        v
Oracle free instance  /srv/watermelon/repo     <-- Watermelon's node, on disk
        |
        |  gotohp-sync.timer, every 10 min
        |  1. wait until a file's size+mtime stopped changing
        |  2. gotohp-cli upload <only the new files>
        v
Google Photos (unlimited, via the native upload path)
```

Everything below was checked against this repository at `v0.11.0` and against
Oracle's current Always Free documentation on 2026-11-04.

## What I verified, and how

| Claim | How it was checked |
| --- | --- |
| Runs headless on Linux, no GUI/X11/GTK | `CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -tags cli` -> 18 MB **statically linked** binary (`ldd`: "not a dynamic executable"); `arm64` -> 17 MB. Both free shapes are covered (Ampere A1 = arm64, E2.1.Micro = amd64). |
| Usable unattended | The CLI has `--no-tui` (no bubbletea renderer without a TTY), prints a JSON summary to stdout, and exits `1` when any file failed. |
| Re-running is cheap and safe | Every file is SHA-1 hashed and checked with `FindRemoteMediaByHash` first; already-present files are skipped as `remote-duplicate` (`core/upload.go`). No `--force` means no duplicates. |
| `--delete` cannot eat a photo on failure | It fires only after a successful commit, or when the file is already in the library. Never on an error path (`uploadSingleFile`, `core/upload.go`). |
| Live Photos survive the trip | Watermelon stores a Live Photo as `IMG_1234.HEIC` + `IMG_1234.MOV` (same stem, original extensions - `RemoteFileNaming.swift`). gotohp pairs exactly that by Apple content identifier, per invocation, with `--pair-live-photos`. |
| The node directory is consumable | Layout is `/{YYYY}/{MM}/` with original filenames, next to `.watermelon_manifest.sqlite` (or `.watermelon/months/<YYYY-MM>.sqlite`), `.watermelon/locks/*.lock` and `.aae` sidecars. gotohp's extension allow-list (`core/upload.go`) drops the non-media files, and `sync.sh` never even passes them. |
| Oracle's free tier is enough | 2 OCPU / 12 GB Ampere A1, or a 1 GB AMD micro, plus 200 GB of block storage in total and a 47 GB minimum boot volume. |

`deploy/oracle-free-tier/test-sync.sh` exercises the whole orchestration with a
stub uploader (no Google account, nothing leaves the machine). Run it before and
after any change:

```shell
bash deploy/oracle-free-tier/test-sync.sh
```

## The two things that will actually bite you

**1. Oracle reclaims idle instances.** An Always Free VM is declared idle if,
for 7 days, p95 CPU < 20%, network < 20%, and (A1 only) memory < 20%. A photo
relay is idle by definition. The documented cure is to **upgrade the account to
Pay As You Go**: Always Free resources stay free, and idleness reclamation stops
applying. Keep the instance inside the free shapes (2 OCPU / 12 GB) so the bill
stays at zero. A keepalive process is the usual workaround, but it burns CPU
precisely to look busy and is not a guarantee.

Related: the A1 allowance was silently halved from 4 OCPU / 24 GB to
2 OCPU / 12 GB on 15 June 2026. Size the shape to 2 / 12 or the instance can be
shut down until it fits.

**2. Disk is the real limit.** Total block storage is 200 GB, including the boot
volume. Because the Watermelon node is kept intact (see below), the instance must
hold the library you are relaying. For libraries bigger than ~150 GB, see
"Running out of disk".

If the Ampere allowance is unavailable (capacity is exhausted most of the time),
take the AMD `VM.Standard.E2.1.Micro` instead: 1 GB RAM and a ~47 GB boot volume
are enough here, because this relay is I/O bound rather than CPU bound. On that
size set `DELETE_AFTER_UPLOAD=true` and back up one month at a time, so the disk
is a buffer rather than an archive. Accept that the node then becomes write-only
scratch: no restore-from-node, and Watermelon may re-send files it can no longer
find.

## Install

Prerequisites: an Ubuntu or Oracle Linux instance in your home region, the boot
volume sized for your library (100 GB is a sane start), and TCP 22 open in the
VCN security list.

**1. Create the instance with your public key, add the repository secrets, and
press Run** on the *Deploy relay to VM* workflow. That is the whole install: the
workflow builds both architectures, ships the matching one, and
`deploy/oracle-free-tier/remote-update.sh` bootstraps the users, the SFTP
chroot, the config and the units on the first run. No compiler, no manual step
and no shell session on the box. Walkthrough: [SETUP.md](SETUP.md).

**2. If you would rather install by hand** (a box with no Actions runner), the
installer still works on its own. It creates the nologin service user, the
chrooted SFTP user, both binaries, the config and the systemd units - and
validates the sshd drop-in with `sshd -t` before reloading, rolling it back if it
is rejected:

```shell
cd gotohp/deploy/oracle-free-tier
sudo ./install.sh --binary ~/gotohp-cli
```

**3. Add a Google account** as the service user (the config holds credentials,
so it lives in `/var/lib/gotohp-sync`, mode 0700, owned by `gotohpsync`):

```shell
sudo -u gotohpsync /usr/local/bin/gotohp-cli creds add - \
  --config /var/lib/gotohp-sync/gotohp.config
```

Paste the `oauth_token` cookie value from `accounts.google.com/EmbeddedSetup`
(the "Embedded setup" flow in the README) and press Ctrl-D. This is the only
sign-in path that needs no rooted Android device, which is exactly what a
headless server needs.

**4. Point Watermelon at it.** New node -> SFTP:

| Field | Value |
| --- | --- |
| Host / port | the instance public IP, 22 |
| Username | `watermelon` |
| Password | the value of the `WATERMELON_SFTP_PASSWORD` secret |
| Base path | `/repo` (inside the chroot) |

Watermelon pins the host key on first use (TOFU). Compare the fingerprint it
shows against `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` before
accepting.

**5. Make sure the date is right, with one photo, before a full backup.** gotohp
takes a photo's Google Photos date from the file's modification time, or from
the filename with `--date-from-filename` (Watermelon's names are `IMG_1234`, so
that flag does nothing here). Watermelon keeps capture time in EXIF safe, but I
could not verify from here whether it also stamps that time onto SFTP uploads.
So: back up **one** month, let it relay, and check that photo's date in Google
Photos. If it shows the upload date instead of 2019, stop and say so - the fix
belongs in `sync.sh`, not in Google Photos.

**6. Turn it on.**

```shell
sudo systemctl start gotohp-sync.service
sudo journalctl -u gotohp-sync.service -f
```

## How the relay behaves

`sync.sh` runs every 10 minutes and is deliberately boring:

- **Quiet interval.** A file is uploaded only if its size *and* mtime are byte
  identical to the previous scan, so a half-finished SFTP upload is never handed
  to Google. On the very first run nothing uploads - it only takes a snapshot.
  This also keeps both halves of a Live Photo in the same invocation, because
  they land seconds apart and then both go quiet together.
- **Ledger.** Finished files are recorded in `/var/lib/gotohp-sync/uploaded.tsv`
  and never hashed again. Losing the ledger is not fatal, just slow: everything
  is re-checked by hash and skipped.
- **Failure isolation.** If a batch fails, the files are retried one at a time to
  find the culprits. A bad file stays pending and is named in the journal while
  the rest of its month uploads normally.
- **Outages.** If not one file can upload on its own, that is treated as an
  account or network problem: nothing is blamed, nothing is marked done, and the
  next run retries the lot. Files are never deleted or parked silently, so a
  broken night costs time, never photos.
- **One run at a time** (`flock`). Uploads run at `Nice=10` / idle I/O so they
  cannot starve the SFTP side.
- **The receiving side is tuned, not throttled.** `sftp-tuning.sh` (installed as
  `gotohp-sftp-tuning`, re-applied on every deploy) sizes the TCP window for a
  long path, stops the congestion window restarting after every quiet gap, turns
  on MTU probing, and skips compression and the 1 GB rekey stall for the phone's
  SFTP sessions. It cannot widen the phone's uplink - that is usually the real
  limit - and it never touches what the relay accepts or where it writes.

State lives in `/var/lib/gotohp-sync` (`uploaded.tsv`, `scan.previous`,
`last-run.json`, `failures.log`, `gotohp.log`). Useful commands:

```shell
# what would be uploaded right now
sudo -u gotohpsync DRY_RUN=true /usr/local/bin/gotohp-sync

# why did something fail (gotohp's own JSON for the failing file)
sudo tail -n 40 /var/lib/gotohp-sync/failures.log

# force one file to be retried even though it is in the ledger
sudo -u gotohpsync sed -i '/IMG_1234.JPG/d' /var/lib/gotohp-sync/uploaded.tsv
```

## Decisions worth knowing

**The node is kept, not drained.** `DELETE_AFTER_UPLOAD=false` by default,
because deleting files out of Watermelon's own repository corrupts its manifests
and index - the node would then no longer be able to restore to the phone, and
Watermelon's next sync would disagree with what is on disk. Keeping it means you
have two independent copies (node + Google Photos) and a restorable node. Turn
deletion on only if you accept that the node becomes write-only scratch space.

With it on, the file is removed by gotohp only after Google confirms the upload,
and a path the ledger already recorded that is on disk again - a file uploaded
before the switch was on, or one Watermelon re-sent - goes back through the same
check instead of being skipped, so the disk is freed rather than filled with
files the relay would otherwise never look at again. The relay itself deletes
nothing: every removal is gotohp confirming against Google first.

**One account, one pipeline.** `ACCOUNT` in the config pins a stored account;
running several relays means several service users, which this does not do.

## Risk and limits

- gotohp is an unofficial client that uploads through the native API without
  counting against quota. That is the whole "unlimited storage" trick, and it is
  not something Google endorses. The risk lands on your Google account, not on
  this VM. Keep an independent copy of anything irreplaceable.
- Watermelon's node credentials live on the instance, and SFTP password auth is
  reachable from the internet. Use a long password; restricting port 22 to your
  carrier's address ranges or reaching the box over Tailscale is better.
- gotohp commits an upload and reports the media key back; the relay trusts that
  and marks the file done. It does not re-download from Google to compare bytes.
- Not tested here, because it needs a real account and a real instance: an actual
  Google Photos upload, a real Oracle VM, and systemd actually firing the timer.
  Everything that could be tested without credentials is covered by
  `test-sync.sh`.

## Files

| File | Purpose |
| --- | --- |
| `install.sh` | Creates users, SFTP chroot, binaries, config, units; validates sshd. |
| `sync.sh` | The relay: stability gate, ledger, batching, failure isolation. |
| `gotohp-sync.service` / `.timer` | Run every 10 min, oneshot, idle priority. |
| `config.env.example` | All tunables, documented. |
| `test-sync.sh` | Contract tests for `sync.sh` with a stub uploader. |
| `SETUP.md` | Account creation to working relay, step by step. |
| `sftp-tuning.sh` | Kernel/sshd settings for the phone's SFTP sessions; `--revert` undoes it. |
| `test-tuning.sh` | Contract tests for `sftp-tuning.sh`, with stubbed sshd and sysctl. |
| `remote-update.sh` | Runs on the VM; bootstraps on first run, then only swaps the binary and units. |

The workflow side is `.github/workflows/deploy-vm.yml` (test, build both
architectures, deploy) and `.github/workflows/vm-command.yml` (run one command
on the box from the Actions tab).
