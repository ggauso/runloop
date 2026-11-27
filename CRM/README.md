# Runloop CRM

Pannello locale per seguire i test di Runloop. Legge in tempo reale lo stesso Supabase usato da iPhone e Apple Watch. L’operatore può consultare un account anche se la persona si è appena registrata e deve ancora confermare l’email.

## Aprire il CRM

Con Docker e il [database di sviluppo Runloop](../README.md#supabase-locale) avviati e le migrazioni dell’app applicate, fare doppio clic su **Apri CRM.command**. Al primo avvio il comando prepara il lettore del database, costruisce il CRM e apre il browser. Per rientrare dopo l’uscita o la scadenza della sessione, usare lo stesso comando.

Dal terminale, nella cartella `CRM/`, si può avviare o aggiornare il servizio con `./start.sh`. Per aprire la sessione eseguire `"./Apri CRM.command"`. Su Linux l’apertura usa `xdg-open`. La pagina risponde su [127.0.0.1:4310](http://127.0.0.1:4310). La sessione dura otto ore e si chiude anche con **Esci** o al riavvio del servizio.

Il CRM e l’app condividono il database. Il CRM ha un proprio progetto Compose, le proprie dipendenze e un proprio ciclo di avvio. Per fermarlo usare `docker compose -f compose.yaml down` da questa cartella. Se Docker gira su Colima e il contesto corrente punta altrove, anteporre `DOCKER_CONTEXT=colima` al comando. Gli script di avvio riconoscono anche questa configurazione.

## Funzionalità e priorità

| Domanda di chi conduce i test | Funzione | Priorità |
| --- | --- | --- |
| La persona si è registrata e ha confermato l’indirizzo? | Ricerca per email, nome o ID, filtro per stato email, data di registrazione e ultimo accesso registrato da Supabase. | Disponibile |
| Quanti iscritti hanno effettivamente usato le funzioni principali? | Utenti attivi distinti, nuove iscrizioni, corse e percorsi negli ultimi 7, 30 o 90 giorni. | Disponibile |
| La corsa di prova è arrivata nell’archivio? | Nella scheda utente si vedono numero di corse completate nel cloud, percorsi salvati e ultima attività. Aggiorna rilegge il database. | Disponibile |
| In quali giorni si sono concentrati i test? | Grafico giornaliero di corse e percorsi, con tabella dei valori. | Disponibile |
| Quanti nuovi iscritti sincronizzano la prima corsa entro sette giorni? | Numero, percentuale sul totale degli iscritti nel periodo e iscritti ancora in tempo per completare il primo invio. | Disponibile |
| Un problema si ripete in sincronizzazione? | Segnalare gli upload ancora incompleti dopo una soglia concordata. Utile distinguere interruzioni temporanee e invii rimasti bloccati. | Se emergono problemi di consegna |
| Su quale versione o dispositivo si presenta un problema? | Valutare eventi diagnostici mirati con versione e piattaforma. Queste informazioni richiedono una raccolta aggiuntiva nell’app. | Da valutare con il pilota |

## Come leggere i numeri

- **Utenti registrati** conta gli account presenti in Supabase Auth, inclusi quelli senza profilo o in attesa di conferma. Gli account anonimi ed eliminati sono esclusi. Il conteggio principale è totale. La nota sottostante indica le nuove iscrizioni nel periodo.
- **Utenti attivi** conta una sola volta ogni account con almeno un percorso salvato o una corsa completata nel cloud nel periodo. L’ultimo accesso è quello registrato da Supabase Auth. Le aperture dell’app e la durata delle sessioni sui dispositivi richiederebbero eventi dedicati.
- **Corse sincronizzate** conta gli allenamenti con upload completo, in base alla data di partenza. Una corsa fatta offline e caricata in seguito compare nel giorno in cui si è corsa. Corse locali e invii incompleti restano esclusi.
- **Prima corsa sincronizzata entro 7 giorni** conta una volta ogni nuovo iscritto che completa un invio entro 168 ore dall’iscrizione, estremi inclusi. La percentuale divide questo numero per tutti gli iscritti nel periodo selezionato. Con zero iscritti appare un trattino. Chi ha ancora tempo per il primo invio resta nel denominatore. Per una corsa offline vale il momento del primo upload completo. Le ritrasmissioni conservano quel momento e il calcolo considera le corse ancora in archivio.
- Per le corse già sincronizzate prima della [migrazione](../Backend/supabase/migrations/20261127100000_first_workout_sync.sql), il database disponeva soltanto dell’ultimo aggiornamento. Il calcolo storico usa quella data e può sottostimare le conversioni se una ritrasmissione è avvenuta dopo la scadenza.
- **Percorsi salvati** conta i percorsi presenti in archivio per data di creazione. Il cambio di nome o la modifica di un percorso conservano la data originaria. La quota del servizio di routing copre una finestra breve e non consente di ricostruire lo storico delle richieste.
- **Ultima attività** è la più recente fra la creazione di un percorso e l’inizio di una corsa sincronizzata. Lo storico della scheda utente considera tutte le date. I conteggi riflettono le cancellazioni effettuate nell’app.
- Le finestre includono il giorno corrente fino all’ora della lettura e i giorni di calendario precedenti, nel fuso **Europe/Rome**.

## Accesso ai dati e sviluppo

Il servizio viene pubblicato sul solo loopback. Chi può eseguire il comando di apertura tramite Docker sul Mac può operare nel CRM. Il comando emette un collegamento monouso valido due minuti e il browser lo scambia con un cookie di sessione HttpOnly. Gli account dei tester restano separati dall’accesso operatore.

`db/install.sql` prepara le viste nello schema privato `runloop_crm`. Il processo web accede come `runloop_crm_reader`, con permesso di lettura sulle sole viste del CRM. Le viste espongono anagrafica, date e conteggi. Coordinate, battito, UUID HealthKit, credenziali e token degli utenti rimangono fuori dal CRM. La password dedicata al database viene generata in `.local/database.env`, esclusa da Git e dall’immagine.

L’interfaccia è in `public/`, il servizio Node in `server/` e le interrogazioni in `db/`. Dopo le modifiche eseguire `./start.sh` per ricostruire l’immagine. L’icona e Barlow Condensed provengono dagli asset condivisi di Runloop. La licenza del font è in `public/Barlow-OFL.txt`.

Per i test dell’accesso, con Node 22 o successivo, eseguire `npm test`. Per verificare le metriche e i permessi, eseguire `./tests/check-db.sh` nel contesto Docker corretto. Quest’ultimo avvia un database temporaneo isolato con le migrazioni dell’app e dati sintetici.
