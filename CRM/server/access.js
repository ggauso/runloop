import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync, readdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

const tickets = join(tmpdir(), 'runloop-crm-tickets');
const ticketLifetime = 2 * 60_000;
const sessionLifetime = 8 * 60 * 60_000;
const sessions = new Map();
const digest = (value) => createHash('sha256').update(value).digest('hex');

export function issueTicket() {
  mkdirSync(tickets, { recursive: true, mode: 0o700 });
  for (const name of readdirSync(tickets)) {
    const file = join(tickets, name);
    try {
      if (statSync(file).mtimeMs + ticketLifetime < Date.now()) unlinkSync(file);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  const ticket = randomBytes(32).toString('hex');
  writeFileSync(join(tickets, digest(ticket)), '', { flag: 'wx', mode: 0o600 });
  return ticket;
}

export function redeem(ticket) {
  if (typeof ticket !== 'string' || !/^[a-f0-9]{64}$/.test(ticket)) return null;
  const file = join(tickets, digest(ticket));
  try {
    const expires = statSync(file).mtimeMs + ticketLifetime;
    unlinkSync(file);
    if (expires <= Date.now()) return null;
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  for (const [id, expires] of sessions) {
    if (expires <= Date.now()) sessions.delete(id);
  }
  const id = randomBytes(32).toString('hex');
  sessions.set(id, Date.now() + sessionLifetime);
  return id;
}

export function sessionId(cookie = '') {
  return /(?:^|;\s*)runloop_crm=([a-f0-9]{64})(?:;|$)/.exec(cookie)?.[1];
}
export const signedIn = (id) => (sessions.get(id) ?? 0) > Date.now();
export const signOut = (id) => sessions.delete(id);
