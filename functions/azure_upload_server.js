'use strict';

const http = require('node:http');
const uploadHandler = require('./azure_upload_handler');
const MAX_BODY_BYTES = 16 * 1024;

function createUploadServer(handler = uploadHandler) {
  return http.createServer({requestTimeout: 30000, headersTimeout: 15000}, async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    if (request.method === 'GET' && request.url === '/healthz') {
      response.end(JSON.stringify({status: 'ok'}));
      return;
    }
    if (request.url !== '/issueReportUploadUrl') {
      response.writeHead(404);
      response.end(JSON.stringify({error: {status: 'NOT_FOUND'}}));
      return;
    }
    let body = '';
    let size = 0;
    request.on('data', chunk => {
      size += chunk.length;
      if (size <= MAX_BODY_BYTES) body += chunk.toString('utf8');
    });
    request.on('error', () => response.destroy());
    request.on('end', async () => {
      if (size > MAX_BODY_BYTES) {
        response.writeHead(413);
        response.end(JSON.stringify({error: {status: 'INVALID_ARGUMENT', message: 'Request is too large.'}}));
        return;
      }
      let data;
      try {
        data = body ? JSON.parse(body) : undefined;
      } catch {
        response.writeHead(400);
        response.end(JSON.stringify({error: {status: 'INVALID_ARGUMENT', message: 'Invalid JSON body.'}}));
        return;
      }
      const context = {};
      try {
        await handler(context, {method: request.method, headers: request.headers, body: data});
        response.writeHead(context.res.status, context.res.headers);
        response.end(JSON.stringify(context.res.body));
      } catch {
        response.writeHead(503);
        response.end(JSON.stringify({error: {status: 'UNAVAILABLE', message: 'Photo upload is temporarily unavailable.'}}));
      }
    });
  });
}

if (require.main === module) {
  const port = process.env.PORT || 8080;
  createUploadServer().listen(/^\d+$/.test(String(port)) ? Number(port) : port);
}

module.exports = {createUploadServer};
