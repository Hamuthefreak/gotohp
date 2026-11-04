// D1 store, used by the Freebuff Sites deployment.
//
// One key/value table holds everything: the relay has one owner, one device and
// one settings document, so a column per concern would be noise.

const SCHEMA = [
	`create table if not exists kv (
     k text primary key,
     v text not null,
     updated_at text not null
   )`,
];

export function d1Store(env) {
	let ready;

	const db = async () => {
		if (!ready) {
			ready = env.DB.batch(SCHEMA.map((sql) => env.DB.prepare(sql)));
		}
		await ready;
		return env.DB;
	};

	return {
		async get(key) {
			const d = await db();
			const row = await d.prepare('select v from kv where k = ?').bind(key).first();
			return row ? row.v : null;
		},

		async set(key, value) {
			const d = await db();
			await d
				.prepare(
					'insert into kv (k, v, updated_at) values (?, ?, ?) on conflict(k) do update set v = excluded.v, updated_at = excluded.updated_at',
				)
				.bind(key, value, new Date().toISOString())
				.run();
		},
	};
}
