# Runloop — Roadmap e task di sviluppo

> **Aggiornamento del 26 novembre 2026.** La fase di sviluppo usa i simulatori Xcode iPhone 17 e Apple Watch Series 11 abbinati.
>
> Le decisioni di prodotto e tecniche sono in [SPEC.md](./SPEC.md). Questo file è la **checklist operativa** e la fonte di verità per lo stato di avanzamento.

## Punto di ripartenza · 26 novembre 2026

| Area | Funzioni disponibili in sviluppo |
| --- | --- |
| Percorsi | Su iPhone si possono scegliere partenza e tappe, generare anelli per distanza, confrontare varianti sulla mappa e salvare, rinominare, eliminare o inviare un percorso al polso. Anche il Watch permette di creare percorsi e varianti tramite l’iPhone raggiungibile con account connesso. La traccia già scaricata resta consultabile al polso offline. |
| Corsa | Si può partire senza login su iPhone o Watch, in corsa libera o seguendo una traccia salvata. Il dispositivo scelto registra tempo attivo, GPS e distanza. Entrambi mostrano passo, battito quando disponibile e cinque zone con obiettivo facoltativo. Il compagno raggiungibile permette di mettere in pausa, riprendere e terminare la stessa corsa. Si può salvare in Salute o scartare con conferma. |
| Storico e account | L’iPhone conserva storico, dettagli e tracce ed esporta in GPX sia i percorsi sia le corse con traccia. Il Watch mostra le corse recenti. Sono disponibili accesso con email, sincronizzazione per account, recupero degli invii dopo la riconnessione e scelta esplicita di associare le corse fatte prima del login. |
| Interfaccia | Il restyle è integrato su entrambi i dispositivi, con animazioni di mappa e selezione, feedback dei comandi, colori di accento e supporto a «Riduci movimento». L’icona e lo splash «Doppio passo» sono nell’app. Riaprendola con una corsa attiva o in pausa si torna al timer. |

**Prove disponibili.** I 15 test di RunloopCore coprono archivio e ritrasmissioni, trasferimento delle tracce lunghe sui simulatori, varianti di percorso, zone cardiache ed esportazione GPX. Le prove di interfaccia sui simulatori hanno verificato il ritorno al timer su entrambi, il mantenimento del tempo di pausa dopo l’interruzione del processo e il comando di pausa dall’iPhone mentre registra il Watch.

**Prova dell’anello sui simulatori.** Il 26 novembre lo schema Xcode ha superato le tre fasi sulla coppia iPhone 17 e Watch Series 11. Con obiettivo 5 km, il percorso generato misurava 4.735 m e la corsa registrata 4.737 m. Dopo la riconnessione, storico e database contenevano una sola corsa con 7 min 32 s di tempo attivo. Tutti i 416 punti del GPX esportato corrispondevano alla registrazione del Watch per ordine, coordinate e orario.

**Ordine di lavoro proposto**

1. Per la regressione del flusso completo è disponibile lo schema Xcode **Anello 5 km**. Crea un percorso con obiettivo 5 km, lo invia al Watch, spegne il simulatore iPhone e registra l’anello con una pausa. Alla riconnessione verifica la ricevuta, una sola voce nello storico, la durata attiva e ogni coordinata e orario del GPX esportato. [Esecuzione della prova](./README.md#test-xcode-dellanello-da-5-km)
2. Rifinire sui simulatori il primo avvio e i messaggi che compaiono quando un permesso viene negato o il servizio percorsi è irraggiungibile. Verificare il ritorno alla rete e ripetere la navigazione con testi grandi e VoiceOver sullo schermo piccolo.
3. Quando saranno disponibili dispositivi fisici, svolgere la prova outdoor F-501 per GPS a schermo spento, battito al polso, consumo batteria e consegna in background. Per il pilota restano da definire l’area geografica coperta e l’ambiente di distribuzione.
4. Dopo il pilota gratuito, sviluppare l’acquisto unico Pro, l’importazione GPX, l’avviso di uscita dal percorso e i parziali e trend. L’esportazione GPX fa già parte della versione gratuita.

## Decisione di prodotto · correre con iPhone o Watch

Il limite osservato nella versione 0.3 è concreto. Su iPhone «Allenamenti» apre uno storico e il dettaglio percorso offre l’invio al polso. Il solo Watch possiede il timer, il registratore GPS e il comando di avvio. Un runner che porta il telefono non può completare il flusso che ha appena preparato.

| Bisogno | Confronto con il mercato | Decisione Runloop |
| --- | --- | --- |
| Partire subito | Runna distingue la corsa libera dall’allenamento pianificato. Strava registra al polso anche lasciando il telefono a casa. [Runna](https://support.runna.com/en/articles/6306200-how-to-use-your-apple-watch-with-runna) · [Strava](https://support.strava.com/en-us/articles/15401820-strava-apple-watch-app) | P0 gratuito. «Corsa libera» e «Inizia corsa» da un percorso su entrambi. Registrazione locale senza login o rete. |
| Capire come sta andando la corsa | Su Runna si può seguire il percorso da entrambi gli schermi. Strava espone tempo, distanza e passo durante la registrazione. [Runna](https://support.runna.com/en/articles/11027305-how-to-follow-a-route-in-the-runna-app) · [Strava](https://support.strava.com/en-us/articles/15401820-strava-apple-watch-app) | P0 gratuito. Tempo attivo, distanza, passo medio, FC quando disponibile e traccia prevista riconoscibile durante la corsa. Pausa, ripresa e fine con conferma. |
| Portare entrambi i dispositivi | Runna consente di leggere le metriche e intervenire sull’allenamento dall’altro dispositivo. Documenta anche il rischio di doppie registrazioni. [Controllo condiviso](https://support.runna.com/en/articles/13620108-apple-watch-workout-mirroring) · [Duplicati](https://support.runna.com/en/articles/9776737-handling-duplicate-activities) | P0 gratuito. Registra il dispositivo scelto alla partenza. Il compagno raggiungibile mostra lo stato e può comandare pausa, ripresa e termine. Alla disconnessione il registratore prosegue. |
| Ritrovare il risultato | Runna conserva un riepilogo dell’attività, con giri e metriche disponibili. [Runna](https://support.runna.com/en/articles/6306200-how-to-use-your-apple-watch-with-runna) | P0 gratuito. Riepilogo immediato, ultime corse consultabili al polso, storico completo e GPX sul telefono. Una corsa corrisponde a un UUID anche dopo ritrasmissione. |
| Allenarsi seguendo un programma | Runna aggiunge obiettivi di passo e avvisi audio durante le sedute. [Indicazioni audio](https://support.runna.com/en/articles/18491520-runna-labs-setting-up-and-managing-your-audio-cues) | Dopo il core. Valutare audio e sedute strutturate dopo la prova sul campo. Parziali e trend restano nel piano Pro ad acquisto unico. |

### F-305 — Parità outdoor e sessione condivisa (P0)

- [x] Avvio autonomo da ciascun dispositivo, libero e da un percorso, metriche, pausa/ripresa, conferma di termine e salvataggio.
- [x] Secondo schermo con stato e comandi della stessa sessione quando le app sono raggiungibili. Un solo dispositivo scrive allenamento e traccia.
- [x] Risultato locale su iPhone anche senza account, riepilogo e consultazione delle corse recenti su Watch.
- [x] Verifica in simulazione dei due dispositivi, del percorso selezionato e del ritorno allo storico. La prova outdoor su dispositivi reali resta in F-501.

### F-306 — Intensità e uscita dalla corsa (P0 gratuito)

La schermata precedente faceva sparire la riga del battito senza campioni, presentava il tempo e le altre metriche con pesi poco distinti e offriva una sola uscita con salvataggio. Un Watch usato come semplice secondo schermo non attiva una registrazione cardiaca al polso.

| Riferimento osservato | Decisione per Runloop |
| --- | --- |
| Apple Allenamento mostra cinque zone e distingue il battito dalla zona attiva. Runna porta la barra di intensità sul polso. [Apple](https://support.apple.com/it-it/guide/watch/apd897dccddf/watchos) · [Runna](https://support.runna.com/en/articles/6306200-how-to-use-your-apple-watch-with-runna) | Mostrare bpm, zona e confronto con un obiettivo facoltativo. Per le zone Runloop l’utente imposta la propria FC massima. Soglie del 60, 70, 80 e 90 per cento. |
| Nell’artefatto Night Pitch la tavola «Loader e micro-interazioni» lega il feedback all’azione. «Dialog e avvisi» riserva una conferma alle decisioni irreversibili. [Prototipo](https://claude.ai/artifact/6gGzzv9B9txErVg6ogjNGg#page-dcb81aee8d83) | Un solo cruscotto per registratore e secondo schermo. Cifre stabili, transizioni brevi, feedback al cambio di stato e conferma esplicita per scartare. |

- [x] Battito con data del campione, stati di attesa e segnale scaduto. Per usare il sensore al polso si può avviare sul Watch anche dall’iPhone quando entrambe le app sono raggiungibili.
- [x] Cinque zone, FC massima e zona obiettivo modificabili durante la corsa. Al polso e sul telefono si vede lo stesso stato. Senza FC massima personale restano disponibili i bpm.
- [x] Da «Termina» si può salvare, tornare alla corsa o confermare lo scarto. Lo scarto rimuove la traccia temporanea e non genera un allenamento in Salute, nello storico o nella coda cloud.
- [x] Verificare sui simulatori interazione locale e remota, salvataggio e scarto. Verifica del sensore fisico in F-501.

## Come usare questo file

- Eseguire **un task ID alla volta**, includendo solo i suoi sotto-task e le dipendenze esplicitamente indicate. Non anticipare altre funzionalità per comodità.
- Prima di ogni task leggere la sezione pertinente di `SPEC.md` e il codice **reale** del repository; non assumere che la struttura sia già stata creata.
- Un task è `DONE` solo quando: i relativi check sono completati, il progetto interessato compila, i test pertinenti passano e i **criteri di accettazione** sono verificati.
- Aggiornare le checkbox **solo dopo** avere effettivamente eseguito le attività; se bloccato, lasciare non spuntato e aggiungere `BLOCKED: motivo` sotto il task.
- Alla fine di ogni task, aggiungere una nota breve in **Registro avanzamento** con ID, esito, file coinvolti, test e problemi residui.
- Non aggiungere framework, servizi o nuovi task salvo richiesta o necessità dimostrata. I task rimangono autonomi nel perimetro dichiarato, non diventano pretesto per refactoring generali.

### Stati e priorità

- `[ ]` non completato · `[x]` completato.
- **P0** indispensabile per il pilota gratuito · **P1** rilascio Pro o evoluzione dopo il pilota.
- Dipendenze indicate con `Dipende da` sono vincolanti; task dello stesso milestone possono procedere indipendentemente se non condividono file o risorse.
- Sviluppo e verifiche funzionali partono dai simulatori iPhone e Apple Watch. Firma, permessi GPS/HealthKit e prova end-to-end su hardware si verificano in F-501 quando i dispositivi sono disponibili.

### Prima sessione Work: bootstrap del progetto

- Lavorare **nella cartella Runloop già esistente** sul computer dell'utente. Esaminare il contenuto prima di creare file; non generare una root omonima annidata e non sovrascrivere modifiche preesistenti.
- Verificare `F-001` per toolchain e compatibilità. Se non sono disponibili Xcode, simulatori o dispositivi fisici, documentare esattamente cosa non si è potuto provare: non spuntare verifiche non eseguite.
- Inizializzare `F-101` (Xcode, target, package, README, Git) e `F-102` (Supabase con Docker Compose ufficiale) come obiettivo della prima sessione. Non anticipare autenticazione, routing, schema DB o schermate di prodotto senza una richiesta esplicita.
- Eseguire i comandi di build e di avvio effettivamente disponibili, riportare output sintetici ed eventuali blocchi e aggiornare le checkbox **solo a verifica avvenuta**.
- Se la sessione Work non dispone di accesso alla cartella locale, indicarlo chiaramente e richiedere che sia resa disponibile; non simulare modifiche al computer dell'utente.

## Riepilogo milestone

| Milestone | Deliverable | Priorità |
| --- | --- | --- |
| **M0 — Validazione tecnica** | Scelte critiche provate su hardware e routing | P0 |
| **M1 — Fondamenta** | Progetto Xcode + Supabase Docker + accesso | P0 |
| **M2 — Percorsi iPhone** | Crea, genera, modifica, salva e visualizza percorsi | P0 |
| **M3 — Allenamento Watch** | Corsa con traccia o libera, registrazione offline | P0 |
| **M4 — Sincronizzazione e storico** | Risultati locali e cloud, esportazione GPX | P0 |
| **M5 — Pilota gratuito** | Verifica end-to-end su iPhone e Watch senza acquisto | P0 |
| **M6 — Rilascio Pro ed evoluzioni** | Acquisto unico, avvisi fuori percorso, import GPX e analisi. Navigazione avanzata e mappe offline successive. | P1 |

---

## M0 — Validazione tecnica (P0)

### F-001 — Verificare i target Apple e le API necessarie
**Dipende da:** nessuno.

- [x] Confermare target **iOS 26+ / watchOS 26+** e toolchain Xcode/SDK compatibili.
- [x] Creare una piccola prova SwiftUI che disegni `MapPolyline` in MapKit sia su iPhone sia su Watch.
- [x] Avviare e abbinare i simulatori iPhone e Apple Watch.

**Verifica** Xcode 26.1.1, iOS/watchOS 26.1 e coppia attiva iPhone 17 / Watch Series 11. Le app MapKit compilano e si avviano. La prova per l'autorizzazione HealthKit e il GPS si avvia sul simulatore Watch.

**Accettazione:** mappe/tracce compilano su entrambi i target e i simulatori risultano abbinati e connessi.

### F-002 — Verificare routing, persistenza e licenze
**Dipende da:** nessuno.

- [x] Avviare GraphHopper con un piccolo estratto OSM e profilo pedonale.
- [x] Provare un percorso A→B con waypoint e un `round_trip` di circa 5 km.
- [x] Verificare che l'output includa una geometria riutilizzabile su MapKit e trasferibile al Watch.
- [x] Documentare limiti/attribuzione OSM e restrizioni di persistenza dati Apple Maps; evitare persistenza di `MKDirections` non verificata.

**Verifica** GraphHopper 10.2 con estratto Monaco. Itinerario con waypoint di 1,13 km e anelli chiusi di 4,21 e 5,50 km con target 5 km. Traccia reale visualizzata su mappa MapKit, serializzazione Codable reversibile e rendering della stessa struttura compilato per watchOS. Il trasferimento fra app è previsto in F-301. Configurazione e riproduzione in [Backend/routing/README.md](./Backend/routing/README.md).

**Accettazione:** una traccia persistibile da GraphHopper è visualizzata su una mappa Apple.

---

## M1 — Fondamenta (P0)

### F-101 — Inizializzare repository e target SwiftUI
**Dipende da:** F-001.

- [x] Esaminare la cartella `Runloop` già creata, incluso lo stato Git, e preservare tutti i file presenti.
- [x] Creare `Runloop.xcodeproj` nella root esistente con target `Runloop` (iOS) e `Runloop Watch` (watchOS), senza directory omonime annidate.
- [x] Configurare bundle ID e firma usando i valori reali del Team di sviluppo, senza inventare identificatori o credenziali.
- [x] Creare il package `RunloopCore` per modelli e contratti condivisi.
- [x] Aggiungere una schermata iniziale minimale su entrambi i target.
- [x] Configurare `.gitignore`, schemi Debug/Release e README con istruzioni di avvio.

**Verifica** Xcode usa il Personal Team `UTZ3WTZ42X` e la firma automatica in Debug e Release per i bundle ID `com.luigiausino.runloop` e `com.luigiausino.runloop.watchkitapp`. Entrambe le app compilano e si avviano sui simulatori senza chiamate al backend. Il provisioning per dispositivi reali rientra in F-501.

**Accettazione:** entrambi i target compilano e si avviano senza backend.

### F-102 — Predisporre Supabase self-hosted in Docker
**Dipende da:** nessuno.

- [x] Integrare la configurazione **ufficiale** Supabase Docker Compose, fissando versione/release.
- [x] Inserire `.env.example` senza segreti; escludere `.env` dal Git.
- [x] Avviare stack e verificare salute database, Auth e REST API.
- [x] Documentare comandi di avvio, stop, log e reset dati locali.

**Verifica:** stack avviato, database sano e `pg_isready` positivo; Auth HTTP 200; REST OpenAPI HTTP 200 con chiave di servizio e richiesta anonima a tabella inesistente HTTP 404 da PostgREST. Il gateway protegge la radice OpenAPI da accesso anonimo.

**Accettazione:** lo stack locale parte da istruzioni riproducibili e risponde alle health check.

### F-103 — Creare schema e politiche di accesso
**Dipende da:** F-102.

- [x] Abilitare PostGIS nello schema `extensions` con migrazione SQL.
- [x] Creare `profiles`, `routes`, `workouts`, `workout_points` secondo `SPEC.md`.
- [x] Aggiungere vincoli, indici, FK, UUID e vincolo univoco sulla sequenza punti.
- [x] Abilitare RLS; testare lettura/scrittura proprie e accesso negato a un altro utente.

**Verifica** Migrazione e test applicati sia a Supabase pulito sia al database locale. PostgREST 14 ha accettato dati GeoJSON e isolato due utenti autenticati. Accesso anonimo e scrittura di punti nell'allenamento altrui negati. Vincoli di deduplicazione e cancellazione verificati in SQL.

**Accettazione:** migrazioni applicabili su DB vuoto; isolamento fra utenti verificato.

### F-104 — Configurare autenticazione e client Supabase su iPhone
**Dipende da:** F-101, F-102, F-103.

- [x] Aggiungere SDK `supabase-swift` con Swift Package Manager.
- [x] Implementare registrazione minima, login/logout **email/password** e ripristino sessione. Verificare l'email con la posta locale di sviluppo.
- [x] Gestire URL/chiave pubblicabile per Debug; nessuna secret key nel client.
- [x] Implementare stati loading, credenziali errate, sessione scaduta e rete assente.
- [x] Rendere lo stato della sessione disponibile alle funzioni online e mantenere accessibile la scheda Allenamenti prima del login. I flussi di routing e storico sono implementati nei task dedicati.

**Verifica** Sul simulatore iPhone, registrazione con email confermata in Inbucket, password errata, login, ripristino a freddo dal Portachiavi e logout. Build Debug e Release compilate. La prova con posta esterna rientra in F-502.

**Accettazione:** l'utente accede, resta autenticato dopo riapertura e può uscire.

---

## M2 — Gestione percorsi su iPhone (P0)

### F-201 — Visualizzare Apple Maps e scegliere la partenza
**Dipende da:** F-101.

- [x] Creare schermata *Nuovo percorso* con `Map` SwiftUI e posizione corrente facoltativa.
- [x] Consentire la scelta manuale del punto iniziale sulla mappa.
- [x] Gestire permesso posizione negato, assenza GPS e loading.
- [x] Visualizzare marker della partenza e ricentrare la mappa.

**Verifica** Su simulatore iPhone 17, selezione con tocco e centro mappa dopo diniego della posizione. La posizione simulata seleziona la partenza e ricentra la camera. L'inquadratura iniziale copre l'estratto locale di Monaco.

**Accettazione:** è possibile scegliere la partenza senza obbligo di concedere GPS.

### F-202 — Integrare GraphHopper nel backend
**Dipende da:** F-002, F-102.

- [x] Aggiungere servizio GraphHopper nel Compose e configurazione regione OSM.
- [x] Esporre operazioni protette per percorso con waypoint e percorso ad anello (Edge Function o piccolo adapter server).
- [x] Validare coordinate, distanza richiesta, numero waypoint, timeout e risposta geometrica.
- [x] Gestire errori di routing senza crash o dati parziali persistiti.
- [x] Misurare volume e latenza delle richieste senza loggare coordinate. Definire limiti operativi anti-abuso uguali per i due livelli di accesso.

**Verifica** Stack Compose sano. Richieste REST con utente GoTrue, waypoint, anello da 5,50 km, area non coperta, input invalido, quota concorrente e timeout con ripristino del servizio verificati. I log contengono stato e durata senza coordinate della prova. Configurazione e contratto in [Backend/routing/README.md](./Backend/routing/README.md).

**Accettazione:** un client autenticato ottiene geometria e distanza; input non validi falliscono chiaramente.

### F-203 — Implementare editor manuale
**Dipende da:** F-104, F-201, F-202.

- [x] Inserire più waypoint nell'ordine scelto.
- [x] Calcolare percorso sul grafo pedonale e visualizzarlo con `MapPolyline`.
- [x] Permettere annullamento ultimo punto, rimozione e ricalcolo.
- [x] Mostrare distanza effettiva e messaggio in caso di percorso non disponibile.

**Verifica** Sul simulatore iPhone, tre punti scelti sulla mappa hanno prodotto un itinerario da 2,04 km. Dopo l'annullamento dell'ultima tappa, l'app ha rimosso l'anteprima e ha calcolato un nuovo itinerario da 1,39 km. Verificata anche la cancellazione dall'elenco dei punti.

**Accettazione:** un percorso con almeno tre punti segue strade/sentieri e può essere modificato.

### F-204 — Generare percorsi ad anello
**Dipende da:** F-104, F-201, F-202.

- [x] Aggiungere modalità *Ad anello* con distanza target in km.
- [x] Richiedere fino a sei proposte variando il `round_trip.seed` in una sola ricerca.
- [x] Mostrare geometria e **distanza effettiva** di ogni alternativa.
- [x] Consentire la scelta della variante; se nessuna è valida, mostrare un errore utilizzabile.
- [x] Rigenerare fino a sei proposte senza salvare. Con almeno due punti in modalità Manuale, generare anche un circuito con le tappe nell'ordine scelto.
- [x] Mostrare il tracciato progressivamente alla selezione di una variante, rispettando Riduci movimento.

**Verifica** Sul simulatore iPhone, con obiettivo 5 km, il primo anello era da 5,50 km e la rigenerazione ha mostrato un altro itinerario da 3,82 km. Con due punti manuali, una prima proposta da 2,07 km è stata seguita da una nuova da 1,96 km mantenendo le due tappe. Verificati il disegno progressivo su registrazione e il vincolo SQL di chiusura.

**Accettazione:** partendo da un punto valido, si può scegliere un anello vicino a 5 km senza promessa di esattezza.

### F-205 — Salvare, elencare e consultare percorsi
**Dipende da:** F-103, F-104, F-203, F-204.

- [x] Salvare nome, modalità, waypoint, geometria OSM, distanze e revisione su Supabase.
- [x] Creare elenco *I miei percorsi* con loading, vuoto, errore e aggiornamento.
- [x] Creare dettaglio con mappa e pulsante *Invia al Watch* (abilitato dal task F-301).
- [x] Permettere rinomina ed eliminazione con conferma; aggiornare la revisione quando cambia la geometria.

**Verifica** Anello da 5,50 km salvato e rinominato sul simulatore iPhone. Dettaglio nascosto dopo logout e itinerario ricaricato dopo il nuovo accesso. Test SQL positivi per isolamento, cancellazione e incremento della revisione sulla sola modifica alla geometria.

**Accettazione:** un percorso salvato riappare dopo logout/login e non è visibile ad altri account.

---

## M3 — Apple Watch e registrazione (P0)

### F-301 — Inviare percorsi dall'iPhone al Watch
**Dipende da:** F-101, F-205.

- [x] Definire DTO `Route`/`SyncEnvelope` in `RunloopCore` con `schemaVersion`.
- [x] Implementare `WCSession` e trasferimento dei percorsi, con consegna file in background sui dispositivi e messaggi interattivi sui simulatori.
- [x] Persistenza locale su Watch e deduplicazione tramite `routeId + revision`.
- [x] Visualizzare su iPhone e Watch gli stati di invio/ricezione; supportare ritrasmissione.

**Verifica** Un anello di 5,5 km inviato dall'iPhone simulato è apparso sul Watch simulato, ha prodotto la conferma di scrittura ed è rimasto disponibile dopo lo spegnimento e riavvio del Watch. I test verificano duplicati, revisioni in ritardo, payload non validi e separazione degli account. La consegna file a distanza e in background sarà verificata in F-501.

**Accettazione:** il percorso resta disponibile sul Watch anche dopo riavvio e lontano dall'iPhone.

### F-302 — Visualizzare percorso e schermata pre-corsa su Watch
**Dipende da:** F-001, F-301.

- [x] Creare elenco percorsi locali e schermata dettaglio.
- [x] Disegnare la traccia con MapKit ove il framework lo consente.
- [x] Aggiungere pulsante *Inizia corsa* e gestione percorso non disponibile.
- [x] Rendere disponibile *Corsa libera* con elenco percorsi vuoto e senza connessione.
- [x] Prevedere fallback leggibile se le tile Apple Maps non sono disponibili offline.

**Verifica** Sul simulatore Watch, l'anello ricevuto si apre come traccia locale anche con il simulatore iPhone spento. Si può passare a MapKit, avviare la corsa con percorso o scegliere Corsa libera.

**Accettazione:** l'utente sceglie una traccia e può iniziare una corsa senza connessione.

### F-303 — Registrare una sessione HealthKit
**Dipende da:** F-101, F-302.

- [x] Richiedere e verificare autorizzazioni HealthKit necessarie.
- [x] Implementare `HKWorkoutSession` outdoor running e `HKLiveWorkoutBuilder`.
- [x] Salvare un workout anche senza `route_id`.
- [x] Mostrare tempo, distanza, passo e FC se autorizzata.
- [x] Implementare pausa/ripresa/fine e salvataggio coerente in Apple Salute.

**Verifica** HealthKit del Watch simulato ha confermato il salvataggio di una corsa con percorso e una corsa libera con iPhone spento. Il tempo è rimasto fermo durante la pausa ed è ripartito alla ripresa. Distanza e frequenza cardiaca misurate dai sensori sono da verificare in F-501.

**Accettazione:** una sessione reale compare in Salute e le metriche non si azzerano durante una pausa.

### F-304 — Acquisire e conservare traccia GPS
**Dipende da:** F-303.

- [x] Prima di avviare una corsa sul Watch, chiedere il permesso di posizione se necessario. Con posizione negata o soggetta a restrizioni, offrire «Corri senza GPS» e «Annulla» anche sull’iPhone collegato. La scelta vale per la singola corsa.
- [x] Registrare punti `lat/lon + timestamp + sequence` con Core Location; gestire precisione variabile.
- [x] Conservare il tempo attivo cumulato con i punti quando disponibile per distinguere le pause nei parziali. Mantenerlo opzionale per tracce precedenti o incomplete.
- [x] Collegare la traccia alla sessione HealthKit con `HKWorkoutRouteBuilder` quando autorizzato.
- [x] Memorizzare localmente i punti in modo incrementale e prepararli in payload trasferibili.
- [x] Testare sul simulatore raccolta in secondo piano, iPhone spento e riapertura app. La prova con schermo spento e assenza di rete resta in F-501.

**Verifica** Corsa libera con GPS simulato, iPhone spento e passaggio in secondo piano: 24 punti, 174,6 m e 84 secondi attivi. Il file finale resta presente dopo la riapertura, con sequenze continue e pausa distinta dalla durata attiva.

**Accettazione:** una corsa reale lascia una traccia persistente, recuperabile dopo fine sessione.

---

## M4 — Sincronizzazione e storico (P0)

### F-401 — Trasferire allenamenti Watch → iPhone
**Dipende da:** F-301, F-303, F-304.

- [x] Definire `Workout`/`SyncEnvelope` condivisi e ID stabile per ogni sessione.
- [x] Aggiungere coda durevole di trasferimento, con `WCSession.transferFile` sui dispositivi e messaggi interattivi sui simulatori.
- [x] Confermare ricezione su iPhone prima della pulizia della coda sul Watch.
- [x] Salvare la sessione su iPhone e renderla disponibile localmente prima di tentare il caricamento cloud.
- [x] Verificare che retry e riavvio non creino allenamenti doppi.

**Verifica** Una corsa da 24 punti registrata a iPhone spento è stata ritrovata in coda dopo il riavvio dell'app Watch. Alla riconnessione è comparsa nello storico iPhone, con conferma di salvataggio. Una ritrasmissione forzata ha lasciato una sola copia. I test coprono anche il payload malformato e la separazione per account.

**Accettazione:** un workout offline raggiunge l'iPhone appena la comunicazione torna disponibile, una sola volta a livello logico.

### F-402 — Caricare workout e GPS su Supabase
**Dipende da:** F-103, F-104, F-401.

- [x] Salvare workout e punti con API idempotenti e batch ragionevoli.
- [x] Associare correttamente utente e percorso pianificato, se presente.
- [x] Gestire upload incompleto, errori temporanei e recupero senza perdita dati.
- [x] Inviare dati HealthKit opzionali solo dopo consenso e senza campioni sanitari grezzi per default.
- [x] Chiedere all'utente se caricare le corse registrate prima dell'accesso. Tenere le code già associate a un account separate durante logout e cambio account.

**Verifica** Upload dal simulatore al Supabase locale di una corsa libera con 24 punti e campi HealthKit vuoti e di una corsa con 15 punti associata all'anello pianificato. Provate entrambe le scelte per una corsa senza account. I test SQL coprono invio parziale, blocco della finalizzazione prematura, ritrasmissione senza duplicati e accesso con un altro account.

**Accettazione:** stesso workout trasferito due volte produce una sola sessione con punti univoci in DB.

### F-403 — Visualizzare storico e dettaglio sull'iPhone
**Dipende da:** F-205, F-402.

- [x] Creare lista degli allenamenti ordinata per data.
- [x] Mostrare durata, distanza, ritmo medio e FC media se presente.
- [x] Visualizzare traccia GPS su Apple Maps e sovrapposizione percorso programmato.
- [x] Gestire dati incompleti, allenamenti senza percorso e stati offline.
- [x] Mostrare gli allenamenti locali registrati prima del login, anche quando il cloud non è configurato.

**Verifica** La corsa ricevuta dal Watch si apre con durata attiva, distanza, passo medio, traccia registrata e percorso pianificato distinti sulla mappa. A gateway spento, resta consultabile la copia locale. La corsa di prova senza GPS mostra lo stato vuoto della traccia.

**Accettazione:** dalla lista si apre una sessione conclusa con statistiche e traccia corretta.

### F-404 — Stato sincronizzazione, privacy e cancellazione
**Dipende da:** F-402, F-403.

- [x] Rendere visibile lo stato *Locale / In coda / Sincronizzato / Errore*.
- [x] Permettere retry senza duplicati e cancellazione di un allenamento con dati associati.
- [x] Eliminare coordinate sensibili dai log e verificare permessi Supabase.
- [x] Documentare quali metriche vengono trasferite al server e come revocare i permessi.

**Verifica** Stati Locale e Sincronizzato verificati sul simulatore. Test Swift e SQL verificano cancellazione, divieto di accesso da un altro account, rimozione dei punti e blocco delle ritrasmissioni dopo cancellazione. La rimozione in differita sul Watch fisico sarà verificata in F-501.

**Accettazione:** l'utente distingue dati locali e remoti e può eliminare i propri allenamenti.

### F-405 — Esportare gratuitamente percorsi e corse in GPX

**Dipende da** F-205, F-403.

- [x] Generare GPX da percorsi salvati e tracce GPS proprie, aggiungendo i timestamp delle corse quando disponibili.
- [x] Aprire la condivisione iOS solo su azione dell'utente. Escludere campioni sanitari e coordinate non incluse nel percorso o nell'allenamento selezionato.
- [x] Verificare che l'esportazione funzioni con dati locali senza acquisto, anche con backend irraggiungibile. Gestire esplicitamente il caso di traccia assente.

**Verifica** Sul simulatore il foglio di condivisione mostra il GPX del percorso e quello della corsa con gateway spento. La validazione GPX 1.1 ha confermato 297 punti con attribuzione OSM per il percorso e 24 punti con orari per la corsa. Le geometrie corrispondono alle sorgenti.

**Accettazione** Un GPX esportato da iPhone senza Pro si apre con la geometria corretta in un lettore compatibile.

---

## M5 — Qualità e rilascio pilota (P0)

### F-501 — Eseguire test end-to-end su dispositivi reali
**Dipende da:** F-401, F-402, F-403, F-404, F-405.

**BLOCKED:** iPhone e Apple Watch fisici non disponibili per il collaudo. Il flusso gratuito è stato verificato sui simulatori.

- [ ] Identificare i dispositivi pilota, completare il provisioning e installare le build firmate su iPhone e Apple Watch.
- [ ] Verificare disponibilità e autorizzazioni di HealthKit e GPS su hardware reale e registrare le limitazioni.
- [ ] Creare anello di circa 5 km e sincronizzarlo sul Watch.
- [ ] Verificare consegna file WatchConnectivity in background, ripresa con Watch raggiungibile, conferma dopo scrittura e apertura del percorso dopo riavvio con iPhone assente.
- [ ] Cancellare una corsa di prova da iPhone e verificare la rimozione sul Watch al successivo contatto.
- [ ] Correre senza iPhone/Internet, mettendo in pausa e riprendendo almeno una volta.
- [ ] Verificare che i punti GPS continuino ad arrivare a schermo spento e che la traccia sia recuperabile in Runloop e in Salute.
- [ ] Terminare, riavviare una delle app prima del sync e verificare recupero.
- [ ] Controllare traccia, metriche, unicità in DB e isolamento tra due account.
- [ ] Ripetere una corsa senza itinerario e prima del login. Verificare storico locale, consenso al caricamento e export GPX senza acquisto.

**Accettazione:** il criterio MVP gratuito di `SPEC.md §8` è verificato su hardware reale.

### F-502 — Stabilizzare il progetto e documentare l'avvio
**Dipende da:** F-501.

- [ ] Rivedere permessi, errori UI, testi accessibili e navigazione Watch.
- [ ] Verificare HTTPS, gestione segreti, RLS e processo di backup se esposto fuori dalla LAN.
- [ ] Verificare consegna e conferma delle email di registrazione nell'ambiente del pilota.
- [ ] Documentare bootstrap Xcode, Docker, migrazioni e deploy pilota.
- [ ] Eseguire build Debug/Release e test disponibili; registrare limitazioni note.

**Accettazione:** un altro sviluppatore può avviare ambiente e app seguendo il README; nessun blocco noto nel flusso MVP.

---

## M6 — Runloop Pro ed evoluzioni successive (P1)

Il pilota copre il flusso gratuito. Dopo la sua verifica, implementare lo sblocco e le tre funzioni Pro.

### F-605 — Implementare lo sblocco unico con StoreKit 2

**Dipende da** F-502.

- [ ] Definire il Product ID e configurare il prodotto non consumabile nel file `.storekit` locale. Mostrare il prezzo localizzato e indicare l'acquisto unico.
- [ ] Verificare acquisto e aggiornamenti StoreKit. Gestire esito in attesa, annullamento, errore temporaneo, revoca, rimborso e riapertura offline.
- [ ] Aggiungere «Ripristina acquisti» in Impostazioni e verificare il recupero su reinstallazione, senza vincolo al login Supabase.
- [ ] Trasmettere al Watch lo stato Pro aggiornato e conservarlo localmente. Verificare che uno stato più vecchio non sovrascriva una revoca già ricevuta.
- [ ] Verificare che il flusso gratuito e i contenuti salvati restino disponibili in tutti gli stati.

**Accettazione** Un solo acquisto di test sblocca Pro dopo una transazione verificata. Il ripristino lo recupera e una revoca verificata lo disattiva anche sul Watch alla successiva sincronizzazione.

### F-601 — Avvisare quando si esce dalla traccia sul Watch (Pro)

**Dipende da** F-304, F-605.

- [ ] Calcolare la distanza dalla traccia già scaricata, usando la precisione GPS, uno scostamento persistente e un intervallo minimo fra avvisi.
- [ ] Offrire un controllo prima della partenza. Confrontare il consumo batteria con una corsa senza avvisi.
- [ ] Testare deviazione reale, ritorno in traccia e GPS impreciso su hardware, con iPhone lontano e rete assente.

**Accettazione** Con Pro sincronizzato il Watch avvisa una volta per uno scostamento persistente e si riattiva dopo il rientro. La registrazione rimane disponibile anche in modalità gratuita o con avvisi disattivati.

### F-602 — Importare un percorso GPX su iPhone (Pro)

**Dipende da** F-205, F-405, F-605.

- [ ] Aprire GPX da File, validare formato, dimensioni e coordinate, e gestire file non validi o senza traccia utilizzabile.
- [ ] Mostrare anteprima, distanza e scelta fra segmenti prima del salvataggio. Evitare collegamenti fittizi fra segmenti.
- [ ] Aggiungere `gpx_import` e provider `gpx` ai contratti e alla persistenza. Verificare la compatibilità con letture e sincronizzazione Watch.

**Accettazione** La geometria importata si salva una sola volta su conferma, compare nell'archivio e arriva sul Watch. Un percorso già importato resta disponibile ed esportabile dopo la revoca di Pro.

### F-603 — Mostrare parziali e trend di corsa su iPhone (Pro)

**Dipende da** F-403, F-605.

- [ ] Calcolare parziali al km dai punti e dal tempo attivo disponibili, distinguendo l'ultimo parziale incompleto. Gestire pause e dati insufficienti.
- [ ] Mostrare confronti settimanali e mensili su distanza, durata e frequenza delle corse. Calcolarli su iPhone usando i dati già disponibili.
- [ ] Verificare storico vuoto, una sola corsa, corse senza traccia e consultazione offline con acquisto già verificato.

**Accettazione** Su uno storico noto, parziali e totali corrispondono ai dati di riferimento. Timeline, metriche base e tracce restano accessibili senza Pro.

### F-606 — Validare il rilascio commerciale

**Dipende da** F-601, F-602, F-603, F-605.

- [ ] Verificare Team titolare iscritto all'Apple Developer Program, bundle ID, record iOS con companion Watch e configurazione App Store Connect. Il titolare cura accordo Paid Apps e dati fiscali e bancari.
- [ ] Configurare in App Store Connect lo stesso Product ID usato in Xcode. Scegliere prezzo e mercati iniziali dopo la verifica dei costi del routing, dell'hosting e del supporto. Preparare metadati e schermate localizzate per l'acquisto unico.
- [ ] Provare in sandbox il flusso free, acquisto, annullamento, ripristino dopo reinstallazione e revoca, anche su una coppia iPhone/Watch. Rieseguire il flusso gratuito dopo la revoca.
- [ ] Verificare cancellazione account dall'app, informative e accesso ai propri dati. Preparare invio della prima In-App Purchase con una versione iOS per App Review.

**Accettazione** I flussi di `SPEC.md §8` sono verificati su hardware, inclusi ripristino e funzioni Pro offline già abilitate. La versione iOS e il prodotto sono pronti per App Review.

### F-604 — Valutare evoluzioni oltre il primo rilascio Pro

**Dipende da** F-606.

- [ ] Valutare indicazioni di svolta, ricalcolo e mappe offline, con test specifici su consumo e disponibilità della cartografia.
- [ ] Valutare dislivello e superficie con fonti affidabili e onboarding con Sign in with Apple.

---

## Criteri generali di completamento

Un task può essere segnato `[x]` soltanto se:

1. Il comportamento richiesto è implementato, senza lavori extra fuori dal task.
2. La build dei target coinvolti è riuscita; i test pertinenti sono stati eseguiti (specificare se serviva hardware non disponibile).
3. È stato verificato almeno il criterio di accettazione scritto nel task.
4. `FEATURE.md` e, **solo se è cambiata una decisione**, `SPEC.md` sono aggiornati.
5. L'implementazione mantiene privacy, licenze cartografiche e vincoli di sicurezza del progetto.

## Registro avanzamento

> Aggiungere righe **solo a lavorazione avvenuta**. Modello: `AAAA-MM-GG | ID | DONE/BLOCKED | File principali | Test effettuati | Note`.

| Data | Task | Esito | File / test | Note |
| --- | --- | --- | --- | --- |
| 2026-11-12 | F-001 | BLOCKED | Xcode 26.1.1, SDK 26.1, `Apps/`; build iOS | Hardware e runtime Watch non disponibili |
| 2026-11-12 | F-101 | BLOCKED | `Runloop.xcodeproj`, `Apps/`, `Packages/`, `README.md`; build iOS simulatore senza firma riuscita | Firma, build Watch e avvio da verificare |
| 2026-11-12 | F-102 | BLOCKED | `Backend/supabase`, `.gitignore`, `README.md`; Compose avviato | Database non sano, vedere log e spazio Docker |

| 2026-11-12 | F-001 | BLOCKED | SDK/runtime 26.1 e build/avvio simulatori iPhone e Watch | Hardware fisico e permessi da verificare |
| 2026-11-12 | F-101 | BLOCKED | `Runloop.xcodeproj`, `README.md`; build e avvio simulatori iOS e watchOS | Firma e bundle ID definitivi da configurare |
| 2026-11-24 | F-101 | BLOCKED | `Runloop.xcodeproj`; firma automatica impostata, build senza firma riuscite per iOS e watchOS | In attesa dell’accesso all’Apple Account privato in Xcode |
| 2026-11-24 | F-101 | BLOCKED | `Runloop.xcodeproj`, `README.md`; Personal Team e bundle ID impostati, build per i due simulatori riuscite | Il Personal Team non ha dispositivi registrati per i profili di sviluppo |
| 2026-11-12 | F-102 | DONE | `.env.example`, `.gitignore`, `README.md`; PostgreSQL, Auth e REST verificati | Disco Colima espanso; vecchi dati incompleti conservati |
| 2026-11-24 | F-002 | DONE | `Backend/routing/`; prove HTTP, MapKit, Codable e compilazione watchOS | Monaco usato per la prova. Copertura pilota da decidere |
| 2026-11-24 | F-103 | DONE | `Backend/supabase/migrations/`, `Backend/supabase/tests/`, `README.md`; SQL su database pulito e locale, test HTTP con due JWT | Verificata compatibilità delle policy con i claim JSON di PostgREST |
| 2026-11-24 | F-202 | DONE | `Backend/routing/`, Edge Function `routing`, migrazione e test quota | Verificati login, richieste riuscite, errori, quota e assenza di coordinate nei log |
| 2026-11-24 | F-001 | BLOCKED | Prova separata HealthKit e GPS compilata e avviata sul simulatore watchOS 26.1 | Xcode non rileva dispositivi fisici disponibili |
| 2026-11-24 | F-001 | DONE | Simulatori iPhone 17 e Watch Series 11 abbinati e connessi; `MapPolyline` verificata | Su indicazione dell'utente, verifica hardware spostata a F-501 |
| 2026-11-24 | F-101 | DONE | `Runloop.xcodeproj`; build e avvio degli schemi iPhone e Watch sui simulatori | Team e bundle ID verificati in Debug e Release |
| 2026-11-24 | F-201 | DONE | `Apps/iOS/RouteStartView.swift`; build iPhone e prove UI sul simulatore | Partenza manuale e uso facoltativo della posizione verificati |
| 2026-11-24 | F-104 | DONE | Client Supabase iPhone, configurazione Debug, posta locale; build Debug/Release e flusso UI | Verificati email locale, credenziali errate, ripristino della sessione e logout |
| 2026-11-24 | F-203 | DONE | Editor e client routing iPhone; build e flusso UI con GraphHopper locale | Traccia con più tappe, attribuzione, rimozione e ricalcolo verificati |
| 2026-11-24 | F-204 | DONE | Editor e client routing iPhone; build e prova UI con anelli reali | Tre varianti generate e cambio di variante verificato |
| 2026-11-24 | F-205 | DONE | Libreria iPhone, migrazione revisione e test SQL; flusso UI sul simulatore | Verificati salvataggio, rinomina, isolamento e ripristino dopo login |
| 2026-11-24 | F-301 | DONE | WatchConnectivity, integrazione del target Watch, test RunloopCore; invio interattivo e riavvio del simulatore | Percorso presente dopo il riavvio; consegna file in background su hardware prevista in F-501 |
| 2026-11-24 | F-302 | DONE | Schermata percorso Watch, traccia locale, MapKit e corsa libera provati sul simulatore | Traccia accessibile con iPhone simulato spento |
| 2026-11-24 | F-303 | DONE | HealthKit watchOS; due corse salvate nel Salute simulato | Pausa e ripresa verificate, una corsa completata con iPhone simulato spento |
| 2026-11-24 | F-304 | DONE | Core Location, registro incrementale, archivio Workout e HealthKit Route | 24 punti GPS simulati persistiti e riletti dopo riapertura con iPhone spento |
| 2026-11-24 | F-401 | DONE | Coda Watch, archivio iPhone, quattro test RunloopCore e prova sui simulatori | Invio dopo riconnessione e ritrasmissione con una sola copia; trasporto file in F-501 |
| 2026-11-24 | F-402 | DONE | Coda cloud iPhone, migrazione `upload_workout_batch`, test SQL e caricamento dal simulatore | Una sessione con 24 punti, campi sanitari esclusi per default |
| 2026-11-24 | F-403 | DONE | Storico e dettaglio iPhone, MapKit e prove sui simulatori | Corsa locale aperta con gateway spento |
| 2026-11-24 | F-404 | DONE | Stati, retry e cancellazione, test Swift e SQL | RLS, cascata sui punti e blocco dei replay verificati |
| 2026-11-24 | F-405 | DONE | GPX condivisibile, archivio percorsi locale, prove UI e validazione GPX 1.1 | Percorso e corsa esportati dal simulatore con gateway spento |
| 2026-11-24 | F-501 | BLOCKED | Flusso gratuito provato su iPhone 17 e Watch Series 11 simulati | Provisioning e collaudo hardware in attesa della disponibilità dei dispositivi |
| 2026-11-25 | F-305 | DONE | Registrazione condivisa iOS/watchOS, storico, archivio e 12 test RunloopCore superati | Corsa libera e su percorso da ciascun simulatore, pausa/ripresa/termine dal compagno in entrambe le direzioni, salvataggio in Salute simulato e una sola voce per corsa dopo la riconnessione. Prova fisica in F-501. |
| 2026-11-25 | F-306 | DONE | Cruscotto e zone condivisi, preferenze per account, registrazione al polso avviata da iPhone. 14 test RunloopCore superati | Verificati il battito sintetico su entrambi gli schermi, la FC massima modificata con la Digital Crown, il recupero con Watch spento e la conferma di scarto. Durante le prove, ogni salvataggio ha prodotto una sola corsa e ogni scarto zero allenamenti e zero tracce residue per quella sessione. Sensore reale in F-501. |
