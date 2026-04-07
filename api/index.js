// Vercel Serverless Function entrypoint.
// Reuses the same Express app as local dev/server.
require("dotenv").config();
const { createApp } = require("../src/backend/app");

module.exports = createApp();

