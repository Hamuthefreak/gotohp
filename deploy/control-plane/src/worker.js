// Cloudflare Worker host for the control plane (Freebuff Sites deployment).
//
// Sign-in is Freebuff's, storage is D1, static files come from the ASSETS
// binding. The routes themselves live in app.js, shared with the Vercel build.
import { createFreebuffAuth, isSameOriginRequest } from '@freebuff/auth';

import { createApp } from './app.js';
import { d1Store } from './store-d1.js';

/** @type {((request: Request, env: Env) => Promise<Response>) | undefined} */
let handler;

function setup(env) {
	if (handler) return handler;

	const auth = createFreebuffAuth({
		clientId: env.FREEBUFF_CLIENT_ID,
		issuer: env.FREEBUFF_ISSUER,
		baseUrl: env.APP_ORIGIN,
		// Loopback only. A deployed origin is https, so this stays off there.
		allowInsecureLocalhost: env.ALLOW_INSECURE_LOCALHOST === '1',
	});

	const routes = createApp({
		store: d1Store(env),
		origin: env.APP_ORIGIN,
		sameOrigin: (request) => isSameOriginRequest(request, env.APP_ORIGIN),
		auth: {
			getUser: (request) => auth.getUser(request),
			loginUrl: '/auth/freebuff/signin?returnTo=/',
			signoutUrl: '/auth/freebuff/signout',
			signoutMethod: 'POST',
			label: 'Sign in with Freebuff',
		},
	});

	/** @typedef {{ASSETS:{fetch(r:Request):Promise<Response>}, DB:D1Database,
	 *   FREEBUFF_CLIENT_ID:string, FREEBUFF_ISSUER?:string, APP_ORIGIN:string}} Env */
	handler = auth.wrap(async (request, env) => (await routes(request, env)) ?? env.ASSETS.fetch(request));
	return handler;
}

export default {
	/** @param {Request} request @param {Env} env */
	fetch(request, env) {
		return setup(env)(request, env);
	},
};
