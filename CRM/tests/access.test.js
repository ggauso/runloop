import test from 'node:test';
import assert from 'node:assert/strict';
import { issueTicket, redeem, sessionId, signedIn, signOut } from '../server/access.js';

test('Il collegamento vale una volta e la sessione viene revocata con Esci', () => {
  const ticket = issueTicket();
  const session = redeem(ticket);
  assert.ok(signedIn(session));
  assert.equal(redeem(ticket), null);
  assert.equal(sessionId('altro=1; runloop_crm=' + session + '; x=y'), session);
  assert.equal(sessionId('altro_runloop_crm=' + session), undefined);
  assert.equal(signedIn(ticket), false);
  signOut(session);
  assert.equal(signedIn(session), false);
});
test('Accessi mancanti, malformati e codici non emessi vengono rifiutati', () => {
  for (const value of [null, '', {}, '0'.repeat(64)]) assert.equal(redeem(value), null);
  assert.equal(signedIn(sessionId()), false);
});
