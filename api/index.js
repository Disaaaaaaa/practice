// Vercel entry point: wraps the same Express app used for local dev
// (server/index.js) as a serverless function. All /api/* routes are
// rewritten here by vercel.json; the app's own route definitions handle
// the rest exactly as they do with `npm start` locally.
module.exports = require('../server/index.js');
