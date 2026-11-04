# SETUP - from an empty Oracle account to a relay that redeploys itself

You create one instance and paste two keys. Everything after that - building the
binary, creating the users, the SFTP chroot, the systemd units, the first Google
account, and every later update - runs in GitHub Actions. There is no shell work
on the VM, ever.

## Who does what

| # | Step | Who | Time |
| --- | --- | --- | --- |
| 1 | Make an SSH keypair | you, 2 commands | 30 s |
| 2 | Oracle account + instance, public key pasted | you, web | 10 min |
| 3 | Four repository secrets | you, web | 5 min |
| 4 | Press *Run workflow* | a button | 3 min |
| 5 | Google `oauth_token` cookie -> one secret, press Run again | you, browser | 2 min |
| 6 | Add the SFTP node in Watermelon | you, app | 2 min |
| - | build, install, chroot, units, retries, later updates | Actions | - |

The keypair is the pipeline's way in: the **public** half is pasted into Oracle
when the instance is created, the **private** half goes into GitHub Secrets.
Never paste the private key into a chat, a file or a screenshot. Keeping it in
Secrets means Actions is the only path into the box, and every change it makes
is logged with the commit that caused it.

## 1. Your only shell commands

**The private key never goes into this chat.** I do not need to see it, and a key
pasted into a conversation is a leaked key. It goes into GitHub Secrets (step 3);
that is what makes the pipeline the only path into the box, with every action
logged against a commit.

### Windows: check your prompt first

The two Windows shells are not interchangeable. `New-Item` does not exist in
`cmd.exe`, and `%USERPROFILE%` is not expanded by PowerShell. Mixing them is what
produces `saving key "$env:USERPROFILE\..." failed: No such file or directory`.

| Prompt | Shell | Use |
| --- | --- | --- |
| `C:\Users\you>` | cmd.exe | the **cmd.exe** block |
| `PS C:\Users\you>` | PowerShell | the **PowerShell** block |

**cmd.exe:**

```cmd
if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
ssh-keygen -t ed25519 -f "%USERPROFILE%\.ssh\gotohp_vm" -C gotohp-vm
```

**PowerShell:**

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\gotohp_vm" -C gotohp-vm
```

Both then ask `Enter passphrase` - **press Enter twice**, it must stay empty. An
Actions runner cannot type a passphrase, so a protected key fails the deploy.

Do not bother with `-N ""` on Windows: cmd passes it awkwardly and Windows
PowerShell 5.1 deletes empty arguments entirely (that is the `Too many arguments`
error). Letting it prompt and pressing Enter is the reliable path.

### macOS / Linux / Git Bash

```shell
ssh-keygen -t ed25519 -f ~/.ssh/gotohp_vm -N "" -C gotohp-vm
```

### What exactly to copy

The `+--[ED25519 256]--+` box of dots and letters is **randomart**: a picture of
the key's fingerprint. Decoration. Nothing in it is copied anywhere.

| File | Looks like | Where it goes |
| --- | --- | --- |
| `gotohp_vm.pub` | **one line**: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... gotohp-vm` | Oracle *Add SSH keys -> Paste public keys*, step 2 |
| `gotohp_vm` | **about 7 lines**, `-----BEGIN OPENSSH PRIVATE KEY-----` to `-----END OPENSSH PRIVATE KEY-----` | the `VM_SSH_KEY` secret, step 3 |

Check both files exist, then open them in Notepad so console line-wrapping cannot
corrupt the copy:

```cmd
dir "%USERPROFILE%\.ssh\gotohp_vm*"
notepad "%USERPROFILE%\.ssh\gotohp_vm.pub"
notepad "%USERPROFILE%\.ssh\gotohp_vm"
```

In PowerShell that is `dir "$env:USERPROFILE\.ssh\gotohp_vm*"` and the same
`notepad` calls with the `$env:` path. Select all (Ctrl+A), copy (Ctrl+C).

### Prove the key is usable

```cmd
ssh-keygen -y -f "%USERPROFILE%\.ssh\gotohp_vm"
```

It must print `ssh-ed25519 AAAA...` **immediately and without prompting**, and the
line must match the one in the `.pub` file. If it asks for a passphrase, the key
is protected: delete both files and repeat this step, pressing Enter at the
prompt.

## 2. Oracle Cloud account and instance

1. Sign up at <https://signup.oraclecloud.com>. A card is required **for identity
   verification only** - Always Free resources stay free. Pick your real home
   region; it cannot be changed later and it decides your latency.
2. **Strongly recommended:** upgrade the account to Pay As You Go in
   *Billing*. Free resources stay free, and it stops the
   [idle reclamation](#10-things-that-bite-later) that would otherwise shut a
   quiet photo relay down after 7 days.
3. *Compute -> Instances -> Create instance*:
   - **Image:** Canonical Ubuntu 24.04
   - **Shape:** `VM.Standard.E2.1.Micro` (always available) or `VM.Standard.A1.Flex`
     with **2 OCPU / 12 GB** if Ampere capacity happens to exist. Do not exceed
     2/12: the A1 allowance was halved on 2026-06-15 and an oversized instance is
     stopped until it fits.
   - **Boot volume:** 100 GB (200 GB is the total free block storage, boot
     included; leave headroom if you ever add a volume).
   - **Add SSH keys -> Paste public keys:** paste the `ssh-ed25519 ...` line
     from step 1. This is the field that gives the pipeline (and me) access.
   - Leave the rest alone and *Create*. Wait for **Running**.
4. Note the **public IPv4 address** - that is `VM_HOST`.
5. Open TCP 22: *Networking -> Virtual Cloud Networks -> your VCN ->
   Security Lists -> Default Security List -> Add Ingress Rule*: source
   `0.0.0.0/0`, protocol TCP, destination port `22`. Watermelon has to reach it
   from your phone and Actions from GitHub.

## 3. Four secrets

<https://github.com/Hamuthefreak/gotohp/settings/secrets/actions> -> *New
repository secret*:

| Name | Value | Required |
| --- | --- | --- |
| `VM_HOST` | the public IP from step 2 | yes |
| `VM_USER` | `ubuntu` | yes |
| `VM_SSH_KEY` | the whole private key block, `-----BEGIN` to `-----END`: `~/.ssh/gotohp_vm` or `%USERPROFILE%\.ssh\gotohp_vm` | yes |
| `WATERMELON_SFTP_PASSWORD` | a password you invent now, 12+ characters | yes |
| `VM_KNOWN_HOSTS` | `ssh-keyscan -t ed25519 <ip>` output | optional, see below |
| `GOOGLE_OAUTH_TOKEN` | slower path - see step 5 | optional |
| `CONTROL_URL` | dashboard origin, from its address bar | optional |
| `CONTROL_DEVICE_TOKEN` | device token, from the dashboard | optional |

`WATERMELON_SFTP_PASSWORD` is what you will type into the Watermelon app, so
choose it here once and reuse it there. Nothing else in the system uses it.

`VM_KNOWN_HOSTS` pins the VM's host key so the workflow notices if someone
swaps the box. Without it the first connection is trusted on contact
(`accept-new`) and the job log prints an `::notice::` saying so - acceptable for
a personal VM, and you can add it later once the host key exists.

## 4. Press the button

*Actions -> **Deploy relay to VM** -> Run workflow -> Run.* The first run does
the whole install:

- runs `test-sync.sh` (the relay's contract tests), so a broken script never ships
- builds `gotohp-cli` for amd64 and arm64, ships whichever matches `uname -m`
- copies the binary, `sync.sh`, `install.sh`, the config template and both units
- `remote-update.sh` proves the new binary runs, then bootstraps: `gotohpsync`
  service user, chrooted `watermelon` SFTP user with the password from the
  secret, `/srv/watermelon/repo`, `/etc/gotohp-sync/config.env`, both units,
  timer enabled
- prints the installed version and `active` for the timer

A green run means the relay is installed. Nothing has been uploaded yet, because
there is no Google account and no photos on the box.

## 5. The Google account

gotohp uploads as a real Google account, and the cookie is the one thing that
cannot be fetched for you - it needs a browser session as that account.

1. Open a **private window**, sign in to the Google account that will receive the
   photos, then go to <https://accounts.google.com/EmbeddedSetup> and finish the
   "I agree" screen.
2. DevTools (F12) -> *Application* -> *Cookies* -> `https://accounts.google.com`
   -> copy the value of **`oauth_token`**.
3. Add it as the secret `GOOGLE_OAUTH_TOKEN`, then re-run the deploy workflow.

That step is skipped when an account is already configured, so re-running is
safe. Prefer doing it by hand? The equivalent, over SSH:

```shell
ssh -i ~/.ssh/gotohp_vm ubuntu@<ip>
sudo -u gotohpsync /usr/local/bin/gotohp-cli creds add - \
  --config /var/lib/gotohp-sync/gotohp.config     # paste the cookie, Ctrl-D
sudo -u gotohpsync /usr/local/bin/gotohp-cli creds list \
  --config /var/lib/gotohp-sync/gotohp.config
```

## 6. Watermelon Backup

New node -> **SFTP**:

| Field | Value |
| --- | --- |
| Host / port | the public IP, `22` |
| Username | `watermelon` |
| Password | the value of `WATERMELON_SFTP_PASSWORD` |
| Base path | `/repo` |

The host key is pinned on first use. To compare fingerprints, run *Run a command
on the relay VM* with
`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` and match the `SHA256:...`
it prints.

## 7. Prove the date before the whole library

gotohp takes a photo's Google Photos date from the file **mtime** (`--date-from-filename`
does nothing for `IMG_1234` names), and SFTP does not reliably carry capture
time over. So before every scan `sync.sh` sets mtime from the date stored in the
file itself (`media-date.py`: EXIF `DateTimeOriginal`, the movie header for
videos, an EXIF-shaped date string as a fallback for HEIC and RAW), and only for
files that have not been uploaded yet. That also makes the date stable, which is
what the quiet-interval gate depends on.

Worth proving on one month first, because a container it cannot parse keeps the
arrival time:

1. Back up **one month only** in Watermelon.
2. Wait for two timer runs (~20 minutes). The first run only takes a snapshot;
   the second uploads, because a file must stop changing first.
3. Look at one photo in Google Photos. **2019 = correct.** Today's date = that
   file carries no date it recognises; tell me which one and `media-date.py`
   grows a reader for it.

Only then start the full backup. A first full push can take hours; the service
timeout is 12 h and the timer picks up where it left off.

## 8. Day-2 operations

- **Updates:** every push to `main` that touches the CLI, `core/`, `internal/`
  or `deploy/oracle-free-tier/` rebuilds and redeploys. That is the whole
  workflow: I push, the VM updates itself, the timer is restarted (never a
  half-finished upload).
- **Anything else:** *Actions -> **Run a command on the relay VM** -> Run
  workflow*, type a command, tick "as root". Output appears in the log. This is
  the supported way to poke the box without a terminal, and it is what I use.

| Question | Command |
| --- | --- |
| Is the timer armed? | `systemctl list-timers gotohp-sync.timer` |
| What did the last run do? | `cat /var/lib/gotohp-sync/last-run.json` |
| Why is it failing? | `journalctl -u gotohp-sync.service -n 100 --no-pager` |
| Which files went up? | `wc -l /var/lib/gotohp-sync/uploaded.tsv` |
| Upload now, ignore the clock | `systemctl start gotohp-sync.service` then read the journal |
| What would it do? | `sudo -u gotohpsync env DRY_RUN=true /usr/local/bin/gotohp-sync` |
| Disk pressure | `df -h / /srv/watermelon` |
| Forgot the SFTP password | `cat /root/watermelon-sftp-password` (only if you left the secret unset) |

## Control dashboard (optional, public URL, one login)

Everything above works through GitHub Actions. This adds a browser dashboard for
the day-to-day: change any upload setting, run the relay now, see what it is
doing. It is public and needs a login, so it is the one part of this setup that
is reachable from the internet.

**How it fits together.** The VM has no domain and no certificate, so it never
accepts a connection for this. The dashboard holds the settings, an agent on the
VM asks for them every minute, applies them and reports state back:

```
browser -> dashboard (Cloudflare Worker)  <-  relay VM asks, every minute
```

Nothing new is opened on the instance. The Worker cannot read your Google
session or your SSH key; neither ever passes through it.

**One-time setup, no shell:**

1. Open the dashboard and click **Sign in with Freebuff**. The first account to
   sign in claims it; any other account gets 403 from then on. Do this yourself
   first, before sharing the URL.
2. Copy the URL from the address bar.
3. Click **Generate device token** and copy the token (shown once).
4. Add two repository secrets under Settings -> Secrets and variables -> Actions:

   | Secret | Value |
   | --- | --- |
   | `CONTROL_URL` | the dashboard origin, e.g. `https://site-....freebuff.page` |
   | `CONTROL_DEVICE_TOKEN` | the token from step 3 |

5. Actions -> **Deploy relay to VM** -> **Run workflow**. It writes the URL into
   `/etc/gotohp-sync/config.env` and the token to
   `/etc/gotohp-sync/device.token`, both root-only, and enables
   `gotohp-control.timer`.

Within a minute the dashboard shows real state: files waiting, disk free, next
run, whether a Google account is configured. Until both secrets exist the agent
stays dormant and does nothing.

**What you can change from it:** pause and resume, run interval, batch size,
threads, storage saver, quota counting, force re-upload, date from filename, type
filter, excluded directories, album (or `AUTO` per folder), account, Live Photo
pairing and its three sub-options, delete after upload, dry run, log level. Plus
**Run now**, **Re-scan files** and **Refresh state**.

A change lands within a minute, and the timer is restarted only when the schedule
itself changed. **Pause** stops the timer without touching files already spooled.

**Where the code lives:** `deploy/control-plane/` (Worker, schema, UI, build) and
`deploy/oracle-free-tier/control-agent.sh` (the VM side). Adding a control is one
entry in `src/schema.js`, one flag in `sync.sh`, one check in `test-sync.sh`.

## 9. When something breaks

| Symptom | Cause | Fix |
| --- | --- | --- |
| `repository secret ... is missing` | step 3 incomplete | add the secret, re-run |
| `'New-Item' is not recognized` | you are in cmd.exe, not PowerShell | use the cmd.exe block in step 1 |
| `saving key "$env:USERPROFILE\..." failed` | PowerShell syntax typed into cmd.exe, so the path was not expanded | same |
| `The system cannot find the path specified` | `%USERPROFILE%\.ssh` does not exist yet | `mkdir "%USERPROFILE%\.ssh"` |
| Watermelon: `Citadel.SFTPMessage.Status/1` | sshd accepted the login, then the session died because `/srv/watermelon/repo` did not exist (a first deploy that failed halfway used to look installed) | re-run **Deploy relay to VM**; fixed versions create it |
| `Too many arguments` from `ssh-keygen` | PowerShell dropped the empty `-N ""` | let it prompt and press Enter twice |
| the deploy asks for a passphrase | the key has one; Actions cannot type it | regenerate without a passphrase (step 1) |
| `Too many arguments` from `ssh-keygen` | PowerShell dropped the empty `-N ""` | use the Windows form in step 1 |
| the deploy asks for a passphrase | the key has one; Actions cannot type it | regenerate without a passphrase (step 1) |
| `Permission denied (publickey)` | private key in `VM_SSH_KEY` does not match the instance | paste the matching `.pub` into the instance's `authorized_keys` via the console |
| `sudo: a password is required` | `ubuntu` lost passwordless sudo | console -> *Console connection*, restore `/etc/sudoers.d/90-cloud-init-users` |
| `the new binary does not run on this host` | wrong architecture shipped | check `uname -m` via *Run a command*; report it |
| `sshd rejected the drop-in` | sshd config conflict | nothing was changed; read the log, `sshd -t` on the box |
| Timer `active` but nothing uploads | no Google account, or files still changing | check `creds list`, then `last-run.json` |
| Photos dated today | the file carried no date `media-date.py` recognises, so mtime is still the arrival time | extend `media-date.py`, or check `journalctl` for the `dated N of M` line |
| Instance stopped itself after a week | idle reclamation | upgrade to Pay As You Go (step 2.2) |
| `No space left on device` | library > boot volume | set `DELETE_AFTER_UPLOAD=true` in `/etc/gotohp-sync/config.env` and relay one month at a time |

## 10. Things that bite later

**Idle reclamation.** An Always Free VM is "idle" if for 7 days p95 CPU < 20%,
network < 20%, and (A1 only) memory < 20%. A photo relay is idle by definition.
Upgrading to Pay As You Go is the documented cure and keeps the free shapes free.

**Disk.** 200 GB total, boot included, and the Watermelon node is kept intact on
purpose (deleting inside a node corrupts Watermelon's manifests and breaks
restore-from-node). For a library larger than the disk, turn
`DELETE_AFTER_UPLOAD=true` on and accept that the node becomes write-only
scratch space.

**Port 22 is open to the world.** Watermelon needs it, so it stays. Long random
password, and consider restricting the source to your carrier's ranges or
fronting it with Tailscale later.

## 11. What is deliberately not automated

- Oracle signup, card verification and instance creation: needs a human and a
  payment identity.
- The Google cookie: needs a browser session as that account.
- The Watermelon node entry: it lives in the app.

Everything downstream of those three is the pipeline's job. Nothing that matters
(credentials, ledger, config) is stored in this repository.
