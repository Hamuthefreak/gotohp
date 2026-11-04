// The settings surface, in one place. The Worker validates against this, the
// dashboard renders its form from it, and the VM agent refuses anything this
// module would have rejected. Adding a control means adding one entry here plus
// the matching read in deploy/oracle-free-tier/sync.sh.
//
// Every key is written into /etc/gotohp-sync/config.env, which sync.sh sources.
// The upload_* keys map to gotohp-cli upload flags; the rest are relay knobs.

/** @typedef {{key:string,label:string,group:string,type:'bool'|'int'|'enum'|'text',
 *   default:string|number|boolean, min?:number, max?:number, options?:string[],
 *   help:string, dangerous?:boolean}} Field */

/** @type {Field[]} */
export const SETTINGS = [
  // ---- schedule ---------------------------------------------------------
  {
    key: 'PAUSED',
    label: 'Paused',
    group: 'Schedule',
    type: 'bool',
    default: false,
    help: 'Stops the timer. Files keep arriving over SFTP and are uploaded when you resume.',
  },
  {
    key: 'SYNC_INTERVAL',
    label: 'Run every',
    group: 'Schedule',
    type: 'enum',
    default: '5min',
    options: ['1min', '2min', '5min', '10min', '15min', '30min', '1h', '3h', '6h', '12h'],
    help: 'How often the relay looks for settled files. Shorter means less spool on disk.',
  },
  {
    key: 'BATCH_SIZE',
    label: 'Files per batch',
    group: 'Schedule',
    type: 'int',
    default: 200,
    min: 1,
    max: 1000,
    help: 'One gotohp invocation handles this many files, so a failure stays small.',
  },

  // ---- upload policy ----------------------------------------------------
  {
    key: 'THREADS',
    label: 'Upload threads',
    group: 'Upload',
    type: 'int',
    default: 3,
    min: 1,
    max: 8,
    help: 'Parallel uploads. Above 4 rarely helps on a free 1 GB box.',
  },
  {
    key: 'SAVER',
    label: 'Storage saver quality',
    group: 'Upload',
    type: 'bool',
    default: false,
    help: 'Compresses to Google Photos storage-saver quality. Faster, smaller, lossy.',
  },
  {
    key: 'USE_QUOTA',
    label: 'Count against storage quota',
    group: 'Upload',
    type: 'bool',
    default: false,
    help: 'Off puts uploads in the original-quality tier that does not consume quota.',
  },
  {
    key: 'FORCE_UPLOAD',
    label: 'Re-upload duplicates',
    group: 'Upload',
    type: 'bool',
    default: false,
    help: 'Uploads even when the file already exists in the library. Creates duplicates.',
    dangerous: true,
  },
  {
    key: 'DATE_FROM_FILENAME',
    label: 'Date from filename',
    group: 'Upload',
    type: 'bool',
    default: false,
    help: 'Takes the date from names like 20240709_182027.jpg instead of the file metadata.',
  },
  {
    key: 'DISABLE_FILTER',
    label: 'Disable type filter',
    group: 'Upload',
    type: 'bool',
    default: false,
    help: 'Hands every file to gotohp instead of only the formats it supports.',
    dangerous: true,
  },
  {
    key: 'EXCLUDE_PATTERN',
    label: 'Exclude directories',
    group: 'Upload',
    type: 'text',
    default: '',
    help: 'Skips directories whose name matches, e.g. @eaDir. Empty means no exclusions.',
  },
  {
    key: 'ALBUM',
    label: 'Album',
    group: 'Upload',
    type: 'text',
    default: '',
    help: 'Album name for everything uploaded, or AUTO to make one album per folder.',
  },
  {
    key: 'ACCOUNT',
    label: 'Google account',
    group: 'Upload',
    type: 'text',
    default: '',
    help: 'Restricts uploads to one stored account. Empty uses the selected one.',
  },

  // ---- live photos ------------------------------------------------------
  {
    key: 'PAIR_LIVE_PHOTOS',
    label: 'Pair Live Photos',
    group: 'Live photos',
    type: 'bool',
    default: true,
    help: 'Sends IMG_1234.HEIC and IMG_1234.MOV together so motion survives.',
  },
  {
    key: 'UPLOAD_INCOMPLETE_LIVE',
    label: 'Upload unpaired halves',
    group: 'Live photos',
    type: 'bool',
    default: false,
    help: 'Uploads a Live Photo member whose partner is missing, as a still file.',
  },
  {
    key: 'UPDATE_EXISTING_TO_LIVE',
    label: 'Upgrade existing photos',
    group: 'Live photos',
    type: 'bool',
    default: false,
    help: 'Attaches matching MOV files to photos already in the library.',
  },
  {
    key: 'IGNORE_APPLE_METADATA',
    label: 'Match by filename',
    group: 'Live photos',
    type: 'bool',
    default: false,
    help: 'Pairs by filename stem instead of Apple content identifiers.',
  },

  // ---- disk -------------------------------------------------------------
  {
    key: 'DELETE_AFTER_UPLOAD',
    label: 'Delete after upload',
    group: 'Disk',
    type: 'bool',
    default: false,
    help: 'Removes each file once Google confirms it. Breaks Watermelon restore for this node.',
    dangerous: true,
  },
  {
    key: 'DRY_RUN',
    label: 'Dry run',
    group: 'Disk',
    type: 'bool',
    default: false,
    help: 'Logs what would be sent and uploads nothing.',
  },

  // ---- logging ----------------------------------------------------------
  {
    key: 'LOG_LEVEL',
    label: 'Log level',
    group: 'Advanced',
    type: 'enum',
    default: 'warn',
    options: ['debug', 'info', 'warn', 'error'],
    help: 'gotohp verbosity. debug fills the journal quickly.',
  },
];

/** Keys the VM agent may write and nothing else may. */
export const KEYS = SETTINGS.map((f) => f.key);

/** Defaults as the string form config.env uses. */
export function defaults() {
  /** @type {Record<string,string>} */
  const out = {};
  for (const f of SETTINGS) out[f.key] = String(f.default);
  return out;
}

/** Only these keys change the timer unit. */
export const TIMER_KEYS = ['SYNC_INTERVAL', 'PAUSED'];

/**
 * Validate one raw value for one key. Returns the canonical string form, or an
 * error message. The agent applies the same rules again on the box.
 * @param {string} key
 * @param {unknown} raw
 * @returns {{value:string}|{error:string}}
 */
export function validateValue(key, raw) {
  const field = SETTINGS.find((f) => f.key === key);
  if (!field) return { error: `unknown setting ${key}` };

  if (field.type === 'bool') {
    if (raw === true || raw === 'true') return { value: 'true' };
    if (raw === false || raw === 'false') return { value: 'false' };
    return { error: `${key} must be true or false` };
  }

  const text = typeof raw === 'string' ? raw.trim() : String(raw ?? '');

  if (field.type === 'int') {
    if (!/^\d+$/.test(text)) return { error: `${key} must be a whole number` };
    const n = Number(text);
    if (field.min !== undefined && n < field.min) return { error: `${key} must be at least ${field.min}` };
    if (field.max !== undefined && n > field.max) return { error: `${key} must be at most ${field.max}` };
    return { value: String(n) };
  }

  if (field.type === 'enum') {
    if (!field.options?.includes(text)) return { error: `${key} must be one of ${field.options?.join(', ')}` };
    return { value: text };
  }

  // Free text lands in a shell-sourced file, so keep it to characters that
  // cannot start a command, a comment or a new line.
  if (text.length > 200) return { error: `${key} is too long (200 characters max)` };
  if (!/^[A-Za-z0-9 @._/-]*$/.test(text)) {
    return { error: `${key} may only contain letters, numbers, spaces and @ . _ / -` };
  }
  return { value: text };
}

/**
 * Validate a whole settings object, filling in defaults for anything absent.
 * @param {Record<string, unknown>} input
 * @returns {{settings:Record<string,string>}|{errors:string[]}}
 */
export function validateAll(input) {
  /** @type {Record<string,string>} */
  const out = defaults();
  const errors = [];
  for (const [key, raw] of Object.entries(input ?? {})) {
    const result = validateValue(key, raw);
    if ('error' in result) errors.push(result.error);
    else out[key] = result.value;
  }
  // Live Photo sub-options are meaningless without pairing, and gotohp-cli
  // rejects them outright; clear them rather than hand it an invalid command.
  if (out.PAIR_LIVE_PHOTOS !== 'true') {
    out.UPLOAD_INCOMPLETE_LIVE = 'false';
    out.UPDATE_EXISTING_TO_LIVE = 'false';
    out.IGNORE_APPLE_METADATA = 'false';
  }
  return errors.length ? { errors } : { settings: out };
}
