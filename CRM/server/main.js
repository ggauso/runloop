import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import pg from 'pg';
import { redeem, sessionId, signedIn, signOut } from './access.js';

const pool = new pg.Pool({
  max: 4,
  connectionTimeoutMillis: 4500,
  options: '-c TimeZone=Europe/Rome -c default_transaction_read_only=on -c statement_timeout=5000'
});
pool.on('error', (error) => console.error('Connessione database interrotta', error.code));
const sql = async (file) => readFile(new URL('../db/' + file, import.meta.url), 'utf8');
const [overview, users] = await Promise.all([sql('overview.sql'), sql('users.sql')]);
const staticFiles = new Map(
  Object.entries({
    '/': ['index.html', 'text/html; charset=utf-8'],
    '/app.js': ['app.js', 'text/javascript; charset=utf-8'],
    '/style.css': ['style.css', 'text/css; charset=utf-8'],
    '/runloop.png': ['runloop.png', 'image/png'],
    '/BarlowCondensed-Bold.ttf': ['BarlowCondensed-Bold.ttf', 'font/ttf']
  })
);
const allowedHosts = new Set(['127.0.0.1:4310', 'localhost:4310']);
const cookieAttributes = '; HttpOnly; SameSite=Strict; Path=/';

function json(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify(value));
}

async function handle(request, response) {
  const host = request.headers.host;
  if (!allowedHosts.has(host) || (request.headers.origin && request.headers.origin !== 'http://' + host)) {
    return json(response, 403, { error: 'Origine non consentita.' });
  }
  const url = new URL(request.url, 'http://' + host);
  const path = url.pathname;
  const asset = staticFiles.get(path);
  if (asset && request.method === 'GET') {
    const data = await readFile(new URL('../public/' + asset[0], import.meta.url));
    response.writeHead(200, { 'Content-Type': asset[1] });
    return response.end(data);
  }
  if (path === '/api/session' && request.method === 'POST') {
    if (request.headers['content-type'] !== 'application/json') return json(response, 415, {});
    let body = '';
    for await (const chunk of request) {
      if (Buffer.byteLength(body) + chunk.length > 512) return json(response, 413, {});
      body += chunk;
    }
    let payload;
    try {
      payload = JSON.parse(body);
    } catch {
      return json(response, 400, {});
    }
    const id = redeem(payload?.ticket);
    if (!id)
      return json(response, 401, { error: 'Il collegamento di accesso è scaduto o è già stato usato.' });
    response.setHeader('Set-Cookie', 'runloop_crm=' + id + '; Max-Age=28800' + cookieAttributes);
    return json(response, 200, { signedIn: true });
  }
  const id = sessionId(request.headers.cookie);
  if (!signedIn(id)) return json(response, 401, { error: 'Accesso operatore richiesto.' });
  if (path === '/api/session' && request.method === 'DELETE') {
    signOut(id);
    response.setHeader('Set-Cookie', 'runloop_crm=; Max-Age=0' + cookieAttributes);
    return json(response, 200, { signedIn: false });
  }
  if (request.method !== 'GET') return json(response, 405, {});
  const params = url.searchParams;
  if (path === '/api/overview') {
    const days = Number(params.get('days') ?? 30);
    if (![7, 30, 90].includes(days)) return json(response, 400, { error: 'Periodo non valido.' });
    const { rows } = await pool.query(overview, [days]);
    return json(response, 200, rows[0]);
  }
  if (path === '/api/users') {
    const search = (params.get('q') ?? '').trim();
    const status = params.get('status') ?? 'all';
    const page = Number(params.get('page') ?? 1);
    if (
      search.length > 200 ||
      !['all', 'confirmed', 'pending'].includes(status) ||
      !Number.isSafeInteger(page) ||
      page < 1 ||
      page > 1000000
    ) {
      return json(response, 400, { error: 'Filtro non valido.' });
    }
    const size = 20;
    const { rows } = await pool.query(users, [search, status, size, (page - 1) * size]);
    return json(response, 200, { ...rows[0], page, size });
  }
  return json(response, 404, {});
}

const server = createServer((request, response) => {
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader(
    'Content-Security-Policy',
    "default-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
  );
  handle(request, response).catch((error) => {
    console.error('Richiesta CRM fallita', error.code ?? error.name);
    if (!response.headersSent)
      json(response, 503, { error: 'Dati non disponibili. Verifica il database Runloop e riprova.' });
    else response.end();
  });
});
server.requestTimeout = 10000;
server.listen(4310, '0.0.0.0');
process.on('SIGTERM', () => server.close(() => pool.end()));
