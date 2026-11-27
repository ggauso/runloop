const $ = (id) => document.getElementById(id);
const rome = 'Europe/Rome';
const dateFmt = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium', timeZone: rome });
const timeFmt = new Intl.DateTimeFormat('it-IT', { dateStyle: 'medium', timeStyle: 'short', timeZone: rome });
const shortDay = new Intl.DateTimeFormat('it-IT', { day: 'numeric', month: 'short', timeZone: rome });
const numbers = new Intl.NumberFormat('it-IT');
let page = 1;
let requestNumber = 0;
let searchTimer;

function el(tag, value, style) {
  const node = document.createElement(tag);
  if (value !== undefined) node.textContent = value;
  if (style) node.className = style;
  return node;
}
function formatDate(value, format = dateFmt) {
  return value ? format.format(new Date(value)) : '—';
}
function dayDate(day, format = shortDay) {
  return formatDate(day + 'T12:00:00Z', format);
}
function showGate(message) {
  $('workspace').hidden = $('nav').hidden = $('logout').hidden = true;
  $('gate').hidden = false;
  $('gate-message').textContent = message + ' Apri «Apri CRM.command» dalla cartella CRM sul Mac.';
  if ($('detail').open) $('detail').close();
  for (const id of ['users', 'recent', 'detail-content', 'metrics', 'chart', 'daily-table', 'first-sync', 'confirmation'])
    $(id).replaceChildren();
}
function showWorkspace() {
  $('gate').hidden = true;
  $('workspace').hidden = $('nav').hidden = $('logout').hidden = false;
}
function notice(message) {
  $('notice').hidden = !message;
  $('notice').textContent = message;
}
function table(headings) {
  const scroller = el('div', undefined, 'scroll');
  const grid = el('table');
  const header = grid.createTHead().insertRow();
  for (const label of headings) {
    const cell = el('th', label);
    cell.scope = 'col';
    header.append(cell);
  }
  scroller.append(grid);
  return [scroller, grid.createTBody()];
}
function badge(account) {
  return el(
    'span',
    account.email_confirmed_at ? 'Confermata' : 'Da confermare',
    account.email_confirmed_at ? 'badge confirmed' : 'badge pending'
  );
}
function detail(account) {
  const identity = el('h3', account.display_name || account.email || account.id);
  const list = el('dl', undefined, 'facts');
  const facts = [
    ['Email', account.email || 'Assente'],
    ['Stato email', badge(account)],
    ['ID account', account.id],
    ['Registrazione', formatDate(account.registered_at, timeFmt)],
    ['Ultimo accesso registrato', formatDate(account.last_sign_in_at, timeFmt)],
    ['Ultima attività', formatDate(account.last_activity_at, timeFmt)],
    ['Percorsi salvati', numbers.format(account.routes)],
    ['Corse sincronizzate', numbers.format(account.workouts)]
  ];
  for (const [label, value] of facts) {
    const dd = el('dd');
    dd.append(value);
    list.append(el('dt', label), dd);
  }
  $('detail-content').replaceChildren(identity, list);
  $('detail').showModal();
}
function userTable(accounts, emptyMessage) {
  if (!accounts.length) return el('p', emptyMessage, 'empty');
  const [node, body] = table(['Utente', 'Registrazione', 'Stato email', 'Corse', 'Percorsi']);
  for (const account of accounts) {
    const row = body.insertRow();
    const cell = row.insertCell();
    const link = el('button', account.display_name || account.email || account.id, 'user-link');
    link.addEventListener('click', () => detail(account));
    cell.append(link);
    if (account.display_name && account.email) cell.append(el('small', account.email));
    row.insertCell().textContent = formatDate(account.registered_at);
    row.insertCell().append(badge(account));
    row.insertCell().textContent = numbers.format(account.workouts);
    row.insertCell().textContent = numbers.format(account.routes);
  }
  return node;
}
function drawChart(daily) {
  const peak = Math.max(1, ...daily.map((d) => d.routes + d.workouts));
  const plot = el('div', undefined, 'plot');
  plot.setAttribute('aria-hidden', 'true');
  const scale = el('div', undefined, 'scale');
  scale.append(el('span', numbers.format(peak)), el('span', '0'));
  const bars = el('div', undefined, 'bars');
  for (const d of daily) {
    const bar = el('div', undefined, 'bar');
    bar.title = dayDate(d.day) + ' · Corse ' + d.workouts + ' · Percorsi ' + d.routes;
    for (const [field, cls] of [
      ['routes', 'route-bar'],
      ['workouts', 'run-bar']
    ]) {
      const part = el('i', undefined, cls);
      part.style.height = (100 * d[field]) / peak + '%';
      bar.append(part);
    }
    bars.append(bar);
  }
  plot.append(scale, bars);
  if (daily.every((d) => !d.routes && !d.workouts))
    plot.append(el('span', 'Nessuna attività nel periodo', 'chart-empty'));
  const axis = el('div', undefined, 'axis');
  for (const pos of [0, Math.floor(daily.length / 2), daily.length - 1])
    axis.append(el('span', dayDate(daily[pos].day)));
  $('chart').replaceChildren(plot, axis);
  const [node, body] = table(['Giorno', 'Corse', 'Percorsi']);
  for (const d of daily.slice().reverse()) {
    const row = body.insertRow();
    for (const value of [dayDate(d.day, dateFmt), d.workouts, d.routes]) row.insertCell().textContent = value;
  }
  $('daily-table').replaceChildren(node);
}
function renderOverview(data) {
  const firstDay = data.daily[0].day;
  $('subtitle').textContent = dayDate(firstDay) + ' – ' + dayDate(data.daily.at(-1).day, dateFmt);
  const metrics = [
    ['Utenti registrati', data.registered, numbers.format(data.new_users) + (data.new_users === 1 ? ' nuovo nel periodo' : ' nuovi nel periodo')],
    ['Utenti attivi', data.active, 'Con corse o percorsi nel periodo'],
    ['Corse sincronizzate', data.workouts, 'Per data della corsa'],
    ['Percorsi salvati', data.routes, 'Creati nel periodo']
  ];
  $('metrics').replaceChildren(
    ...metrics.map(([label, value, hint]) => {
      const card = el('article', undefined, 'metric');
      card.append(el('h2', label), el('strong', numbers.format(value)), el('p', hint));
      return card;
    })
  );
  const { new_users: signups, first_sync_in_week: converted, first_sync_pending: pending } = data;
  const conversion = signups ? new Intl.NumberFormat('it-IT', { style: 'percent', maximumFractionDigits: 1 })
    .format(converted / signups) : '—';
  const fraction = numbers.format(converted) + ' su ' + numbers.format(signups) +
    (signups === 1 ? ' nuovo iscritto nel periodo' : ' nuovi iscritti nel periodo');
  const activation = $('first-sync');
  activation.replaceChildren(el('strong', conversion, 'percentage'), el('p', fraction));
  if (pending) {
    const message = pending === 1 ? ' iscritto ha ancora tempo per sincronizzare.' : ' iscritti hanno ancora tempo per sincronizzare.';
    activation.append(el('p', numbers.format(pending) + message, 'pending-sync muted'));
  }
  drawChart(data.daily);
  const percent = data.registered ? Math.round((data.confirmed * 100) / data.registered) : null;
  const track = el('div', undefined, 'track');
  const fill = el('i');
  fill.style.width = (percent ?? 0) + '%';
  track.append(fill);
  const breakdown = el('dl', undefined, 'breakdown');
  for (const [label, value] of [
    ['Confermate', data.confirmed],
    ['Da confermare', data.registered - data.confirmed]
  ]) {
    breakdown.append(el('dt', label), el('dd', numbers.format(value)));
  }
  $('confirmation').replaceChildren(
    el('strong', percent === null ? '—' : percent + '%', 'percentage'),
    el('p', 'degli account registrati', 'muted'),
    track,
    breakdown
  );
  $('recent').replaceChildren(userTable(data.recent_users, 'Nessun utente registrato.'));
  $('updated').textContent = 'Dati letti il ' + formatDate(data.as_of, timeFmt) + ' · Ora di Roma';
}
function renderUsers(data) {
  $('users').replaceChildren(userTable(data.users, 'Nessun utente corrisponde ai filtri selezionati.'));
  const pages = Math.max(1, Math.ceil(data.total / data.size));
  $('page-info').textContent =
    numbers.format(data.total) +
    (data.total === 1 ? ' utente' : ' utenti') +
    ' · Pagina ' +
    page +
    ' di ' +
    pages;
  $('prev').disabled = page <= 1;
  $('next').disabled = page >= pages;
  $('pagination').hidden = false;
  $('updated').textContent = 'Corse e percorsi si riferiscono all’intero storico sincronizzato.';
}

async function load() {
  clearTimeout(searchTimer);
  const seq = ++requestNumber;
  const onUsers = location.hash === '#utenti';
  const view = $(onUsers ? 'directory' : 'overview');
  $('overview').hidden = true;
  $('directory').hidden = !onUsers;
  $('users').hidden = $('pagination').hidden = true;
  $('period-control').hidden = onUsers;
  $('updated').textContent = '';
  $('title').textContent = onUsers ? 'Utenti' : 'Panoramica';
  $('subtitle').textContent = onUsers ? 'Account registrati su Runloop' : '';
  document.title = $('title').textContent + ' · Runloop CRM';
  for (const a of $('nav').children) {
    if (a.hash === (onUsers ? '#utenti' : '#panoramica')) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  }
  notice('Caricamento dei dati…');
  const params = onUsers
    ? new URLSearchParams({ q: $('search').value.trim(), status: $('status').value, page })
    : new URLSearchParams({ days: $('period').value });
  try {
    const response = await fetch('/api/' + (onUsers ? 'users?' : 'overview?') + params);
    if (seq !== requestNumber) return;
    if (response.status === 401) return showGate('Per consultare i dati serve una sessione operatore.');
    showWorkspace();
    const data = await response.json();
    if (seq !== requestNumber) return;
    if (!response.ok) throw new Error(data.error || 'Richiesta non riuscita.');
    if (onUsers) {
      const lastPage = Math.max(1, Math.ceil(data.total / data.size));
      if (page > lastPage) {
        page = lastPage;
        return load();
      }
      renderUsers(data);
    } else {
      renderOverview(data);
    }
    notice('');
    view.hidden = false;
    $('users').hidden = !onUsers;
  } catch (error) {
    if (seq !== requestNumber) return;
    showWorkspace();
    notice(error instanceof TypeError ? 'Collegamento interrotto. Riprova con Aggiorna.' : error.message);
  }
}
async function start() {
  const match = /^#accesso=([a-f0-9]{64})$/.exec(location.hash);
  if (match) {
    history.replaceState(null, '', '/');
    try {
      const response = await fetch('/api/session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ticket: match[1] })
      });
      if (!response.ok) return showGate('Il collegamento di accesso è scaduto o è già stato usato.');
    } catch {
      return showGate('Servizio irraggiungibile.');
    }
  }
  await load();
}
$('period').onchange = $('refresh').onclick = load;
$('status').onchange = () => {
  page = 1;
  load();
};
$('search').oninput = () => {
  page = 1;
  ++requestNumber;
  clearTimeout(searchTimer);
  searchTimer = setTimeout(load, 180);
};
$('prev').onclick = () => {
  if (page > 1) {
    page--;
    load();
  }
};
$('next').onclick = () => {
  page++;
  load();
};
$('close').onclick = () => $('detail').close();
$('logout').onclick = async () => {
  try {
    const response = await fetch('/api/session', { method: 'DELETE' });
    if (!response.ok && response.status !== 401) throw new Error();
    ++requestNumber;
    clearTimeout(searchTimer);
    showGate('Sessione chiusa.');
  } catch {
    notice('Uscita non riuscita. Riprova.');
  }
};
window.addEventListener('hashchange', () => {
  page = 1;
  start();
});
start();
