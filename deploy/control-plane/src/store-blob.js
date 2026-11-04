// Vercel Blob store, used by the Vercel deployment.
//
// Blob is a file store, not a key/value database, so every key becomes one JSON
// object under a prefix. Reads pass `useCache: false`, which bypasses the CDN
// and returns what was written last: the dashboard polls this every few
// seconds, and a version cached for up to a minute would look like a stalled
// relay. The store is private, so reading at all needs the project's token.
import { get, put } from '@vercel/blob';

const PREFIX = 'gotohp/';

export function blobStore(env) {
	const token = () => env.BLOB_READ_WRITE_TOKEN;

	return {
		async get(key) {
			const result = await get(`${PREFIX}${key}.json`, { access: 'private', useCache: false, token: token() });
			if (!result || !result.stream) return null;
			return new Response(result.stream).text();
		},

		async set(key, value) {
			await put(`${PREFIX}${key}.json`, value, {
				access: 'private',
				addRandomSuffix: false,
				allowOverwrite: true,
				contentType: 'application/json',
				cacheControlMaxAge: 60,
				token: token(),
			});
		},
	};
}
