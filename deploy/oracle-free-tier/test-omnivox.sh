#!/usr/bin/env bash
# Proves omnivox-mcp.sh generates the right unit and environment before a deploy
# ships them to the box. No box, no node, no network: every check is on the text
# the installer would write and on its argument handling.

set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
SELF=./omnivox-mcp.sh
pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() {
	printf '  FAIL %s\n' "$1"
	fail=$((fail + 1))
}

has() {
	local label=$1 needle=$2 hay=$3
	if [[ $hay == *"$needle"* ]]; then
		ok "$label"
	else
		no "$label (missing: $needle)"
	fi
}

lacks() {
	local label=$1 needle=$2 hay=$3
	if [[ $hay == *"$needle"* ]]; then
		no "$label (unexpected: $needle)"
	else
		ok "$label"
	fi
}

# shellcheck source=omnivox-mcp.sh
OMNIVOX_LIB=1 . "$SELF"

echo 'environment file'
env_text=$(render_env)
has 'sets the port' 'PORT=3000' "$env_text"
has 'points the server at the data folder' "OMNIVOX_DATA_DIR=$DATA" "$env_text"
has 'keeps the puppeteer cache inside the prefix' "PUPPETEER_CACHE_DIR=$PREFIX/.puppeteer" "$env_text"
lacks 'keeps the browser out of the re-fetched checkout' "PUPPETEER_CACHE_DIR=$APP" "$env_text"
has 'a slow page cannot kill the server' 'NODE_OPTIONS=--unhandled-rejections=warn' "$env_text"
has 'asks chrome to sleep between requests' 'BROWSER_SLEEP=true' "$env_text"
has 'disables the sandbox for this kernel' '--no-sandbox' "$env_text"
has 'avoids the 64 MB /dev/shm' '--disable-dev-shm-usage' "$env_text"
lacks 'never carries the access key' 'accessKey' "$env_text"
lacks 'never carries a session cookie' '"cookies"' "$env_text"

PORT=4567
has 'a --port override reaches the file' 'PORT=4567' "$(render_env)"
PORT=3000
BROWSER_SLEEP=false
has 'a resident browser is possible' 'BROWSER_SLEEP=false' "$(render_env)"
BROWSER_SLEEP=true

first=$(render_env)
second=$(render_env)
if [[ $first == "$second" ]]; then
	ok 'rendering twice is identical (a redeploy changes nothing)'
else
	no 'rendering twice is identical'
fi

echo 'environment migration'
# An install from before the browser moved keeps its old env file, and that file
# points the server at a Chrome the update just deleted. Repair it, keep edits.
tmp_env=$(mktemp)
printf 'PORT=3000\nPUPPETEER_CACHE_DIR=%s/app/.puppeteer\nBROWSER_SLEEP=false\n' "$PREFIX" >"$tmp_env"
ENV_FILE=$tmp_env migrate_env_paths >/dev/null
migrated=$(cat "$tmp_env")
has 'repairs a stale browser path' "PUPPETEER_CACHE_DIR=$PREFIX/.puppeteer" "$migrated"
lacks 'leaves no stale path behind' "$PREFIX/app/.puppeteer" "$migrated"
has 'keeps an edited setting' 'BROWSER_SLEEP=false' "$migrated"
lacks 'adds no duplicate path' "$(printf 'PUPPETEER_CACHE_DIR=%s\nPUPPETEER_CACHE_DIR=' "$PREFIX/.puppeteer")" "$migrated"
printf 'PORT=3000\n' >"$tmp_env"
ENV_FILE=$tmp_env migrate_env_paths >/dev/null
has 'adds the path to a file that predates it' "PUPPETEER_CACHE_DIR=$PREFIX/.puppeteer" "$(cat "$tmp_env")"
printf 'PUPPETEER_CACHE_DIR=%s\n' "$PREFIX/.puppeteer" >"$tmp_env"
ENV_FILE=$tmp_env migrate_env_paths >/dev/null
has 'a correct file is left alone' "PUPPETEER_CACHE_DIR=$PREFIX/.puppeteer" "$(cat "$tmp_env")"
rm -f "$tmp_env"

echo 'surviving a rejected promise'
# A rejected promise nobody caught ended the whole server on 2026-11-26. The
# setting lives in the env file, which survives an upgrade, so it has to be
# added there too.
tmp_env=$(mktemp)
printf 'PORT=3000\nBROWSER_SLEEP=false\n' >"$tmp_env"
ENV_FILE=$tmp_env migrate_unhandled_rejections >/dev/null
rej=$(cat "$tmp_env")
has 'adds the setting to an env file that predates it' 'NODE_OPTIONS=--unhandled-rejections=warn' "$rej"
has 'keeps the rest of the file' 'BROWSER_SLEEP=false' "$rej"
ENV_FILE=$tmp_env migrate_unhandled_rejections >/dev/null
rej=$(cat "$tmp_env")
count=$(grep -c '^NODE_OPTIONS=' "$tmp_env")
((count == 1)) && ok 'a second run adds no duplicate' || no "a second run adds no duplicate (found $count)"
printf 'NODE_OPTIONS=--max-old-space-size=256\n' >"$tmp_env"
ENV_FILE=$tmp_env migrate_unhandled_rejections >/dev/null
rej=$(cat "$tmp_env")
has 'replaces a setting that would abort on rejection' 'NODE_OPTIONS=--unhandled-rejections=warn' "$rej"
lacks 'leaves no second NODE_OPTIONS' 'max-old-space-size' "$rej"
rm -f "$tmp_env"
unit=$(render_unit)
has 'runs as the service user' 'User=omnivox' "$unit"
has 'runs from the source directory' "WorkingDirectory=$APP" "$unit"
has 'reads the environment file' "EnvironmentFile=$ENV_FILE" "$unit"
has 'starts the project the way it documents' 'ExecStart=/usr/bin/npm start' "$unit"
has 'comes back after a crash' 'Restart=always' "$unit"
has 'signals npm and kills its children' 'KillMode=mixed' "$unit"
has 'caps memory' 'MemoryMax=768M' "$unit"
has 'allows a little swap before the cap' 'MemorySwapMax=1G' "$unit"
has 'privacy of the data folder' 'UMask=0077' "$unit"
has 'cannot escalate' 'NoNewPrivileges=yes' "$unit"
has 'writes only inside the prefix' "ReadWritePaths=$PREFIX" "$unit"
has 'is enabled at boot' 'WantedBy=multi-user.target' "$unit"

echo 'argument handling'
echo 'start decision'
# The server exits immediately when config.json is missing. A unit that starts
# anyway turns that into a crash loop, so this branch is the one that matters.
tmp=$(mktemp -d)
DATA=$tmp
if [[ $(start_decision) == wait ]]; then
	ok 'waits for a session instead of crash-looping'
else
	no 'waits for a session instead of crash-looping'
fi
printf 'x' >"$tmp/cookies.json"
printf 'x' >"$tmp/config.json"
if [[ $(start_decision) == start ]]; then
	ok 'starts once both files are present'
else
	no 'starts once both files are present'
fi
rm -rf "$tmp"

rc=0
validate_port 3000 || rc=$?
((rc == 0)) && ok 'accepts the default port' || no 'accepts the default port'
for bad in 80 0 65536 99999 abc ''; do
	rc=0
	validate_port "$bad" || rc=$?
	((rc != 0)) && ok "rejects port '${bad}'" || no "rejects port '${bad}'"
done

rc=0
validate_ref main || rc=$?
((rc == 0)) && ok 'accepts an ordinary branch' || no 'accepts an ordinary branch'
rc=0
validate_ref v3.8.0 || rc=$?
((rc == 0)) && ok 'accepts a tag' || no 'accepts a tag'
for bad in 'main; rm -rf /' '$(id)' 'a..b' '' '-x'; do
	rc=0
	validate_ref "$bad" || rc=$?
	((rc != 0)) && ok "rejects ref '${bad}'" || no "rejects ref '${bad}'"
done

rc=0
bash "$SELF" --help >/dev/null 2>&1 || rc=$?
((rc == 0)) && ok '--help exits 0' || no '--help exits 0'

rc=0
bash "$SELF" nonsense >/dev/null 2>&1 || rc=$?
((rc == 2)) && ok 'an unknown command exits 2' || no "an unknown command exits 2 (got $rc)"

rc=0
bash "$SELF" --port 12 status >/dev/null 2>&1 || rc=$?
((rc == 2)) && ok 'a bad --port is refused before anything runs' || no "a bad --port is refused (got $rc)"

rc=0
bash "$SELF" session >/dev/null 2>&1 || rc=$?
((rc != 0)) && ok 'session without files fails instead of half-importing' || no 'session without files fails'

echo 'upstream download patch'
patch_root=$(mktemp -d)
mkdir -p "$patch_root/src/omnivox-api/puppet" "$patch_root/src/common"
cat >"$patch_root/src/omnivox-api/puppet/download.ts" <<'TS'
        if (redirected && contentType.startsWith('text/html')) {
            await res.body.dump();
            throw new Error('Omnivox redirected the download to a web page instead of a file. The session has probably expired, log in again with the auth app.');
        }
TS
cat >"$patch_root/src/common/downloads.ts" <<'TS'
    const name = path.basename(file.filename || fallbackName).replace(/[<>:"/\\|?*\x00-\x1f]/g, '_');
    const filePath = path.join(downloadsDir, name);
    await pipeline(file.body, fs.createWriteStream(filePath));

    return filePath;
TS
out=$(python3 ./patch-download-guard.py "$patch_root" 2>&1)
fetch_text=$(cat "$patch_root/src/omnivox-api/puppet/download.ts")
save_text=$(cat "$patch_root/src/common/downloads.ts")
has 'the fetch guard is applied' 'looksLikeErrorPage' "$fetch_text"
has 'the Error.txt name is refused' '^error\.(txt|html?)' "$fetch_text"
lacks 'the redirect-only guard is gone' 'if (redirected && contentType.startsWith' "$fetch_text"
has 'the save guard is applied' 'Omnivox sent an HTML page instead of' "$save_text"
has 'the written page is deleted before failing' 'fs.unlinkSync(filePath);' "$save_text"
has 'both guards report that they applied' 'save guard: applied' "$out"

out2=$(python3 ./patch-download-guard.py "$patch_root" 2>&1)
has 'a second run is a no-op' 'already applied' "$out2"
count=$(grep -c 'const looksLikeErrorPage' "$patch_root/src/omnivox-api/puppet/download.ts")
((count == 1)) && ok 'the guard is not applied twice' || no "the guard is not applied twice (found $count)"

printf 'const x = 1;\n' >"$patch_root/src/common/downloads.ts"
rc=0
python3 ./patch-download-guard.py "$patch_root" >/dev/null 2>&1 || rc=$?
((rc != 0)) && ok 'a moved upstream anchor fails loudly' || no 'a moved upstream anchor fails loudly'
rm -rf "$patch_root"

echo 'upstream MIO guard'
# Omnivox accepts a delete or restore for an id that does not exist, and a
# folder with no name, without an error - so `.then(r => !!r)` reported work it
# never did. The guard proves the effect instead; these checks keep it.
mio_root=$(mktemp -d)
mkdir -p "$mio_root/src/omnivox-api/requests"
cat >"$mio_root/src/omnivox-api/requests/Mio.ts" <<'TS'
export function GetListeFoldersModel() {
    return omnivox.postJson<MioFolders.ResponseModel>(
        '/Mobl/Mio/GetListeFoldersModel',
        {}
    );
}

export function DeleteMessage(messageId: string) {
    return omnivox.postJson<any>(
        '/Mobl/Mio/DeleteMessage',
        {
            "Id": messageId,
            "SupprimerPermanent": false,
            "Envoie": false
        }
    ).then(r => !!r);
}

export function RestoreMessage(messageId: string) {
    return omnivox.postJson<any>(
        '/Mobl/Mio/RestoreMessage',
        {
            "Id": messageId,
            "Envoie": false
        }
    ).then(r => !!r);
}

export function AjoutCategorie(nomCategorie: string) {
    return omnivox.postJson<any>(
        '/Mobl/Mio/AjoutCategorie',
        {
            "nomCategorie": nomCategorie
        }
    ).then(r => !!r);
}
TS
out=$(python3 ./patch-mio-guard.py "$mio_root" 2>&1)
mio_text=$(cat "$mio_root/src/omnivox-api/requests/Mio.ts")
has 'the delete proves the trash count moved' 'nothing moved' "$mio_text"
has 'the restore proves it too' 'export async function RestoreMessage' "$mio_text"
has 'an unnamed folder is refused' "A folder needs a name" "$mio_text"
has 'an existing folder is refused' 'already exists' "$mio_text"
has 'a create is proved by the folder list' 'the folder list does not contain it' "$mio_text"
# grep exits 1 when it finds nothing, which is the good case here.
left=$(grep -c 'then(r => !!r)' "$mio_root/src/omnivox-api/requests/Mio.ts" || true)
if [[ $left == 0 ]]; then
	ok 'no verbatim false success is left in those three'
else
	no "no verbatim false success is left (found $left)"
fi
has 'all three guards report that they applied' 'create-folder guard: applied' "$out"

out2=$(python3 ./patch-mio-guard.py "$mio_root" 2>&1)
has 'a second run is a no-op' 'already applied' "$out2"
count=$(grep -c 'async function movedTrashCount' "$mio_root/src/omnivox-api/requests/Mio.ts")
((count == 1)) && ok 'the guard is not applied twice' || no "the guard is not applied twice (found $count)"

# The guard has to behave, not just exist: run it against a stub Omnivox.
if command -v node >/dev/null 2>&1; then
	guard_out=$(node ./check-mio-guard.mjs "$mio_root" 2>&1)
	rc=$?
	if ((rc == 0)); then
		ok 'a bogus id fails, a real one works, an empty name is refused'
	else
		no 'the guard reports only work it can see'
		printf '%s\n' "$guard_out" | sed 's/^/       /'
	fi
else
	echo '  skip node is not installed here; the deploy self-tests the guard on the box'
fi

printf 'const x = 1;\n' >"$mio_root/src/omnivox-api/requests/Mio.ts"
rc=0
python3 ./patch-mio-guard.py "$mio_root" >/dev/null 2>&1 || rc=$?
((rc != 0)) && ok 'a moved upstream anchor fails loudly' || no 'a moved upstream anchor fails loudly'
rm -rf "$mio_root"

echo 'upstream extra read tools'
# Three read tools upstream has no tool for, a guard on MIO attachment ids, and a
# pre-flight that refuses a build whose tool modules do not all load. A module
# that throws on load exits the whole server (seen with delete-mio-message), and
# a fork would be wiped by the next fetch_source - so this is a re-applied patch.
ex_root=$(mktemp -d)
mkdir -p "$ex_root/src/omnivox-api/requests" "$ex_root/src/express/routes" "$ex_root/src/mcp/tools/courses"
printf 'import { omnivox } from "../puppet";\n\nexport function GetListeActualite(count: number = 21) {\n    return omnivox.postJson<any>("/Mobl/College/ListeActualite", { NombreItem: count });\n}\n' >"$ex_root/src/omnivox-api/requests/College.ts"
printf 'export function GetMioAttachment(messageId: string, attachmentId: string): Promise<DownloadResult> {\n    return fetchDownload(\`/Mobl/Mio/GetMioAttachment?\${messageId}\`, {});\n}\n' >"$ex_root/src/omnivox-api/requests/Mio.ts"
printf 'import * as express from "express";\nconst router = express.Router();\nrouter.get("/tools", (a, b) => b.json({}));\nexport default router;\n' >"$ex_root/src/express/routes/tools.ts"
printf 'const tool = 1;\n' >"$ex_root/src/mcp/tools/courses/documents.ts"
out=$(python3 ./patch-extra-tools.py "$ex_root" 2>&1)
has 'the college document tool is added' 'get-college-document-link' "$(cat "$ex_root/src/mcp/tools/extra/college-document-link.ts" 2>/dev/null)"
has 'it reads the document list the app already fetches' 'ListeDocumentsMessages?.ListeDocuments' "$(cat "$ex_root/src/mcp/tools/extra/college-document-link.ts" 2>/dev/null)"
has 'it saves the file the document points at' 'PathFichier' "$(cat "$ex_root/src/mcp/tools/extra/college-document-link.ts" 2>/dev/null)"
has 'the MIO attachment tool is added' 'get-mio-message-link' "$(cat "$ex_root/src/mcp/tools/extra/mio-message-link.ts" 2>/dev/null)"
has 'it checks the pair before asking Omnivox' 'ResolveMioAttachment' "$(cat "$ex_root/src/mcp/tools/extra/mio-message-link.ts" 2>/dev/null)"
has 'the campus events tool is added' 'get-campus-events' "$(cat "$ex_root/src/mcp/tools/extra/campus-events.ts" 2>/dev/null)"
has 'the events list request is added' 'export async function GetListeEvenement' "$(cat "$ex_root/src/omnivox-api/requests/College.ts")"
# The endpoint Omnivox actually serves. The first version of this patch asked
# for one that answers only an error page, and a box that ran it kept it.
lacks 'it asks for the endpoint the app calendar uses, not one that 404s' "ListeEvenement'" "$(cat "$ex_root/src/omnivox-api/requests/College.ts")"
has 'and an older copy of the request is replaced, not skipped' 'EvenementsWeb_GetFirstLoad' "$(cat "$ex_root/src/omnivox-api/requests/College.ts")"
has 'a wrong attachment id names the ones that exist' 'has no attachment' "$(cat "$ex_root/src/omnivox-api/requests/Mio.ts")"
has 'the attachment itself is still fetched as before' 'export function GetMioAttachment' "$(cat "$ex_root/src/omnivox-api/requests/Mio.ts")"
has 'the pre-flight script is added' 'registered > 0' "$(cat "$ex_root/scripts/toolscheck.ts" 2>/dev/null)"
has 'it says what it applied' 'attachment guard: applied' "$out"
# The guard must not add a second declaration of the function it anchors on.
att=$(grep -c 'export function GetMioAttachment' "$ex_root/src/omnivox-api/requests/Mio.ts")
((att == 1)) && ok 'the attachment function is declared once' || no "the attachment function is declared once (found $att)"
out2=$(python3 ./patch-extra-tools.py "$ex_root" 2>&1)
has 'a second run is a no-op' 'events list: already applied' "$out2"
events=$(grep -c 'function GetListeEvenement' "$ex_root/src/omnivox-api/requests/College.ts")
((events == 1)) && ok 'the events request is added once' || no "the events request is added once (found $events)"
printf 'export function Other() {\n    return 1;\n}\n' >"$ex_root/src/omnivox-api/requests/Mio.ts"
rc=0
python3 ./patch-extra-tools.py "$ex_root" >/dev/null 2>&1 || rc=$?
((rc != 0)) && ok 'a moved upstream anchor fails loudly' || no 'a moved upstream anchor fails loudly'
rm -rf "$ex_root"

# The installer has to call both: fetch the patch, and refuse a build whose tool
# modules do not all load before the unit is restarted.
installer=$(cat "$SELF" 2>/dev/null || cat ./omnivox-mcp.sh)
has 'the installer applies the extra tools patch' 'patch-extra-tools.py' "$installer"
has 'the installer checks every tool module before shipping' 'toolscheck || warn' "$installer"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
