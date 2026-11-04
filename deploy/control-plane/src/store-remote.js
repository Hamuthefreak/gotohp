// Storage for the Vercel build: the D1 database behind the Freebuff Sites
// deployment of this same app, reached through a small shared-secret API.
//
// Vercel Blob cannot host this relay on the free plan: a 60-second device
// heartbeat is 43,200 operations a month on its own, against an allowance of a
// few thousand, and the dashboard polls every few seconds on top of that. D1 has
// orders of magnitude more headroom, so the Vercel functions keep their own URL
// and password and use D1 for the data.
//
// Reads are memoised for a moment: one dashboard refresh reads six keys and the
// page polls every few seconds, so without this a single open tab would make the
// round trips multiply.
const TTL_MS = 1500;
const memo = new Map();

function memoised(key) {
	const hit = memo.get(key);
	if (!hit) return undefined;
	if (Date.now() - hit.at > TTL_MS) {
		memo.delete(key);
		return undefined;
	}
	return hit.value;
}

export function remoteStore(env) {
	const base = () => String(env.STATE_URL || '').replace(/\/+$/, '');
	const secret = () => String(env.STATE_SECRET || '');

	async function call(path, body) {
		const response = await fetch(`${base()}${path}`, {
			method: 'POST',
			headers: { 'content-type': 'application/json', authorization: `Bearer ${secret()}` },
			body: JSON.stringify(body),
		});
		if (!response.ok) {
			const detail = (await response.text()).slice(0, 120);
			throw new Error(`relay state ${path} failed: ${response.status} ${detail}`);
		}
		return response.json();
	}

	return {
		async get(key) {
			const hit = memoised(key);
			if (hit !== undefined) return hit;
			const body = await call('/api/state/get', { keys: [key] });
			const value = typeof body?.[key] === 'string' ? body[key] : null;
			memo.set(key, { at: Date.now(), value });
			return value;
		},

		async set(key, value) {
			await call('/api/state/set', { key, value });
			memo.set(key, { at: Date.now(), value });
		},
	};
}
