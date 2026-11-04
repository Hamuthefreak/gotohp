// One function for every API path.
//
// Vercel's file-system routing wants a file per route, and a Hobby deployment
// allows only twelve functions. That limit silently 404'd routes we had added
// before (/api/accounts/*, /api/device/pair): the code existed, the URL did not.
// A single catch-all hands the full path to src/app.js, which already routes on
// it, so adding a route is now a one-file change with no hosting quota involved.
export { default, config } from './_lib/handler.js';
