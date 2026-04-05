#!/usr/bin/env node

/**
 * Tiny HTTP server for sandbox conformance tests.
 * Returns { "mock": true, "path": "<request path>" } for every request.
 * Starts on port 18923 by default.
 */

import { createServer } from 'node:http';

const PORT = parseInt(process.env.MOCK_PORT || '18923', 10);

const server = createServer((req, res) => {
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ mock: true, path: req.url }));
});

server.listen(PORT, () => {
  process.send?.('ready');
});

export default server;
