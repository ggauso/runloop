# Runloop — Specifiche di prodotto e tecniche

> **Versione:** 0.3 · **Data:** 24 novembre 2026 · **Stato:** specifica di prodotto
>
> Questo documento descrive **cosa** deve realizzare il progetto. La pianificazione esecutiva, con task e sotto-task, è in [FEATURE.md](./FEATURE.md).

## 1. Visione e perimetro

Runloop è un'app nativa **iPhone + Apple Watch** per progettare itinerari di corsa, seguirli e registrare l'allenamento. È anche un **progetto pilota Swift/SwiftUI**: privilegiare API native, codice leggibile e incrementi piccoli rispetto a infrastrutture o astrazioni premature.

Runloop si scarica gratis. Il **MVP gratuito** serve a dimostrare l'intero flusso di corsa su hardware reale. **Runloop Pro** è un unico acquisto in-app non consumabile, senza rinnovo, da offrire dopo il pilota gratuito. L'acquisto sblocca strumenti aggiuntivi per preparare, seguire e analizzare gli allenamenti.

### Obiettivi MVP

1. Creare su iPhone un percorso **manuale** (punti intermedi con calcolo della traccia) o **automatico ad anello** (distanza desiderata, partenza e varianti).
2. Vedere il percorso su **Apple Maps** e salvarlo nell'account.
3. Trasferirlo sull'**Apple Watch** prima di partire.
4. Correre **senza iPhone e senza Internet**, con un itinerario o in modalità corsa libera, registrando GPS, tempo, distanza, ritmo e, se autorizzata, frequenza cardiaca.
5. Ritrovare il risultato sull'iPhone e sincronizzare lo storico con il backend quando la connessione torna disponibile.
6. Esportare gratuitamente come GPX una propria traccia o un proprio percorso salvato.

### Fuori perimetro MVP

- App macOS o Android; piattaforme cross-platform (React Native/Flutter).
- Social, classifiche, sfide, abbonamenti, suggerimenti AI.
- Navigazione turn-by-turn con istruzioni vocali/aptiche e ricalcolo in tempo reale.
- Garanzia di **cartografia offline**: la registrazione deve funzionare offline; le tile della mappa non sono garantite.
- Dislivello accurato, analisi biomeccanica, coaching e piani di allenamento.
- Condivisione pubblica dei percorsi. Importazione GPX, analisi avanzata e avvisi fuori percorso sono previsti dopo il pilota come funzionalità Pro.

## 2. Piattaforme e stack

| Area | Decisione |
| --- | --- |
| Target | **iOS 26+ e watchOS 26+**, da verificare sui dispositivi pilota |
| Linguaggio e UI | **Swift, SwiftUI** |
| Organizzazione codice | Due app target Xcode + package Swift condiviso (`RunloopCore`) |
| Gestione asincrona | Swift Concurrency (`async/await`), `Observable` ove appropriato |
| Mappe visibili | **Apple MapKit**, `Map`, `Marker`, `MapPolyline` su iPhone e Watch |
| Localizzazione | **Core Location** |
| Allenamenti | **HealthKit**, `HKWorkoutSession`, `HKLiveWorkoutBuilder`, `HKWorkoutRouteBuilder` |
| Watch ↔ iPhone | **WatchConnectivity** per consegna percorsi e trasferimento risultati |
| API / Auth / DB | **Supabase self-hosted**, SDK Swift ufficiale |
| Database geografico | **PostgreSQL + PostGIS** |
| Container | **Docker Compose** (stack ufficiale Supabase, più routing separato) |
| Routing persistente | **GraphHopper self-hosted** con dati OpenStreetMap |
| Routing di prova | `MKDirections` solo per eventuali anteprime temporanee A→B |
| Acquisto Runloop Pro | **StoreKit 2**, un acquisto non consumabile sull'app iPhone |

### Identità del progetto e convenzioni

- **Nome del prodotto:** **Runloop** su iPhone e Apple Watch.
- **Root di lavoro:** usare la cartella `Runloop` che l'utente ha già creato sul proprio computer; rispettarne il nome effettivo e non creare una seconda cartella `Runloop` annidata.
- **Progetto Xcode:** `Runloop.xcodeproj` nella root del repository.
- **Target Xcode:** `Runloop` (iOS) e `Runloop Watch` (watchOS).
- **Swift Package condiviso:** `RunloopCore`, usato solo per modelli e logica realmente comuni.
- **Repository Git:** nome logico `runloop`; preservare `.git`, branch, file e remoti se già presenti.
- **Identificatori Apple:** il progetto locale usa `com.luigiausino.runloop` e `com.luigiausino.runloop.watchkitapp` con il Personal Team `UTZ3WTZ42X`. Prima del rilascio, verificare la registrazione dei bundle ID sul Team titolare della distribuzione.
- **Backend:** usare `runloop` come etichetta di progetto; non alterare senza motivo i nomi dei database e dei servizi interni richiesti dalla configurazione ufficiale di Supabase.

**Scelta fondamentale:** le **mappe mostrate sono Apple Maps** su entrambi i dispositivi; il motore di routing può usare **OpenStreetMap senza mostrarne le tile**. GraphHopper serve perché occorrono itinerari ad anello e una geometria trasferibile/conservabile in modo indipendente da Apple Maps. Non introdurre MapLibre o un tile server OSM nel MVP.

**Nota licenze:** non persistere né replicare nel backend dati cartografici/itinerari ottenuti da Apple Maps al di fuori dei limiti previsti dai termini Apple. È consentito memorizzare i **punti immessi dall'utente**, le **tracce GPS rilevate dall'app** e le **geometrie ottenute dal routing OSM**, nel rispetto delle licenze applicabili. Verificare attribuzione OSM/ODbL e condizioni di GraphHopper prima del rilascio pubblico. Non assumere che una mappa scaricata nell'app Mappe di Apple sia accessibile offline alla nostra app.

## 3. Esperienza utente

### iPhone — Schermate MVP

| Schermata | Comportamento minimo |
| --- | --- |
| Accesso | Login email/password Supabase per routing online e sincronizzazione cloud. Le corse ricevute prima dell'accesso sono consultabili nello storico locale. |
| Percorsi | Lista dei percorsi privati, stato, distanza, apertura dettaglio |
| Crea percorso | Mappa Apple, punto iniziale, modalità *Manuale* / *Ad anello* |
| Editor | Aggiunta/rimozione/riordino waypoint, anteprima linea, distanza |
| Generatore | Distanza target in km, punto iniziale, fino a quattro proposte |
| Dettaglio percorso | Nome, mappa, distanza effettiva, salvataggio, «Invia al Watch» ed esportazione GPX |
| Allenamenti | Lista sessioni concluse, riepilogo metriche, traccia registrata ed esportazione GPX |
| Impostazioni | Unità metriche, permessi, stato collegamento Watch, logout, privacy |

**Percorso manuale:** la linea segue il grafo pedonale. Con almeno due punti l'utente può calcolare una tratta aperta oppure generare un anello che visita i punti nell'ordine scelto e torna alla partenza con un rientro distinto. È possibile rimuovere e reinserire i waypoint.

**Percorso automatico:** selezione di partenza e distanza indicativa (es. 8 km). GraphHopper `round_trip` restituisce varianti cambiando il `seed`. In entrambe le modalità ad anello si possono cercare altre proposte dalla stessa anteprima e salvare solo la variante scelta. Mostrare la distanza effettiva. Se la ricerca fallisce, conservare l'anteprima disponibile. La traccia calcolata si disegna dalla partenza, oppure appare subito con Riduci movimento.

### Apple Watch — Schermate MVP

1. **Percorsi disponibili:** elenco sincronizzato localmente, stato del download e azione **Corsa libera** disponibile anche con elenco vuoto.
2. **Prima della corsa:** nome, distanza, anteprima della traccia; avvio esplicito.
3. **Corsa in corso:** tempo, distanza, ritmo corrente/medio, FC se autorizzata; posizione e traccia sulla mappa quando disponibili.
4. **Pausa / Riprendi / Termina:** pulsanti evidenti e prevenzione dei tap accidentali.
5. **Riepilogo:** sessione salvata localmente, stato «Da sincronizzare» o «Sincronizzato».

La Watch app **non deve chiedere credenziali** né contattare direttamente Supabase: i dati passano attraverso l'iPhone associato. Con un percorso già scaricato o in corsa libera, l'allenamento deve poter partire ed essere salvato anche con l'iPhone lontano.

### Cosa include Runloop Pro

| Area | Runloop gratuito | Runloop Pro, acquisto unico |
| --- | --- | --- |
| Preparazione | Editor manuale, generatore ad anello con fino a quattro proposte, archivio privato e invio al Watch | Importazione di GPX da File su iPhone, con anteprima e salvataggio nella stessa libreria |
| Corsa | Corsa libera o lungo la traccia già scaricata, GPS offline, pausa/ripresa, metriche e salvataggio in Salute | Avviso aptico di uscita dal percorso su Watch, calcolato localmente in base a traccia e qualità GPS |
| Dopo la corsa | Storico completo, traccia GPS, confronto visivo con il percorso pianificato, sincronizzazione e export GPX | Parziali al km e confronti settimanali/mensili su distanza, durata e frequenza delle corse |

- **Import GPX** da File su iPhone. Validare formato, dimensione e coordinate, poi mostrare distanza e anteprima. Se contiene più segmenti, farne scegliere uno senza collegare le interruzioni. Il percorso importato usa il normale flusso di salvataggio e invio al Watch.
- **Avvisi sul Watch** calcolati dalla traccia locale e da una posizione GPS sufficientemente affidabile. Avvisare solo per scostamenti persistenti, con una pausa fra avvisi e riattivazione al rientro in traccia. Lasciare il controllo all'utente prima della partenza. La registrazione prosegue con GPS debole o senza avvisi.
- **Analisi** calcolate su iPhone con i dati disponibili. Distinguere il parziale finale e segnalare quando i dati non bastano per ricostruire un parziale attendibile. I riepiloghi avanzati non richiedono nuovi campioni sanitari.
- Mostrare **«Sblocca Runloop Pro»** in Impostazioni e quando si apre una funzione Pro, con il prezzo localizzato restituito da StoreKit e la dicitura «acquisto unico». La schermata d'acquisto è chiudibile e non interrompe una corsa, un invio o l'accesso ai propri dati.

## 4. Flussi principali

### A. Pianificazione e trasferimento

1. L'utente entra nell'app iPhone e sceglie *Nuovo percorso*.
2. Seleziona la partenza; imposta waypoint oppure distanza target e anello.
3. L'app richiede il routing; il backend restituisce geometria, distanza, metadati e provider.
4. L'utente sceglie una variante, rinomina e salva su Supabase.
5. L'iPhone trasferisce al Watch **identificativo + versione + metadati + geometria**.
6. Il Watch salva il pacchetto localmente e conferma la ricezione; i tentativi successivi non generano duplicati.

### B. Registrazione dell'allenamento

1. Dal Watch l'utente seleziona un percorso oppure *Corsa libera* e avvia `HKWorkoutSession` (*outdoor running*).
2. Core Location registra timestamp e coordinate, HealthKit raccoglie i dati autorizzati.
3. La sessione prosegue senza connettività; i dati vengono persistiti in modo incrementale e recuperabile.
4. Pausa/ripresa mantengono coerenti tempo attivo e distanza.
5. A fine corsa il Watch conclude la sessione, salva l'allenamento in Salute, conserva un riepilogo locale e mette in coda il trasferimento all'iPhone.
6. L'iPhone rende disponibile il risultato nello storico locale. Se l'utente è autenticato, carica il risultato su Supabase con deduplicazione basata su ID stabile. Per una corsa registrata prima dell'accesso, l'utente sceglie se caricarla sul proprio account.

### C. Consultazione

1. L'utente apre *Allenamenti* su iPhone.
2. Vede data, distanza, durata, ritmo medio, FC media (se disponibile), traccia GPS e percorso pianificato, quando presente.
3. Se offline, visualizza i dati disponibili localmente e lo stato di sincronizzazione; alla riconnessione ritenta.
4. Da un percorso salvato o un allenamento con traccia esportabile, genera un GPX e sceglie dalla condivisione di sistema dove salvarlo o a chi inviarlo. L'export standard contiene la geometria e, quando disponibili per una corsa, gli orari dei punti. I campioni sanitari restano esclusi.

## 5. Contratti dati minimi

Usare **UUID** stabili generati all'origine; timestamp **UTC**; distanza in **metri**; durata in **secondi**; passo in **s/km**; FC in **bpm**; coordinate **WGS84** (`lat`, `lon`) e geometrie PostGIS **SRID 4326**. Convertire le unità solo in UI.

| Tabella | Campi principali / note |
| --- | --- |
| `profiles` | `id` UUID collegato ad `auth.users`, `display_name`, `created_at`, `updated_at` |
| `routes` | `id`, `owner_id`, `name`, `mode` (`manual`,`round_trip`,`waypoint_loop`), `target_distance_m`, `distance_m`, `waypoints` JSONB, `geometry` LineString 4326, `provider`, `revision`, timestamps. Con l'import Pro aggiungere `gpx_import` e provider `gpx` tramite migrazione compatibile con le app già distribuite. |
| `workouts` | `id`, `owner_id`, `route_id` nullable, `healthkit_workout_uuid` nullable, `started_at`, `ended_at`, `active_duration_s`, `distance_m`, `avg_pace_s_per_km`, `avg_heart_rate_bpm` nullable, timestamp |
| `workout_points` | `workout_id`, `sequence`, `recorded_at`, `position` Point 4326, `active_elapsed_s` opzionale per distinguere il tempo attivo alle pause, eventuale `speed_mps`; chiave univoca (`workout_id`, `sequence`) |

- **RLS obbligatoria** su tutte le tabelle utente: solo il proprietario può leggere/scrivere i dati, incluse le tracce GPS. Testare anche accesso fra due utenti distinti.
- Indici almeno su `owner_id`, `started_at`, `route_id` e, ove utili, indici spaziali GiST. Definire vincoli FK e policy di cancellazione coerenti.
- **Niente segreti server** nel client: solo URL e chiave pubblicabile Supabase; service role / secret key soltanto lato server.
- I dati grezzi dei sensori sanitari restano locali per impostazione predefinita; inviare al backend soltanto statistiche selezionate ed esplicitamente autorizzate. Le tracce GPS sono dati personali sensibili nel contesto d'uso: informativa chiara, cancellazione e nessun logging delle coordinate.
- Il database è la fonte di verità per percorsi e storico sincronizzato; il Watch è la fonte di origine dell'allenamento fino a conferma di caricamento.
- Isolare cache e coda cloud per account. Solo le corse locali mai associate a un account possono essere proposte per il caricamento al primo accesso.

### Payload concettuali

- `Route`: `id`, `revision`, `name`, `waypoints[]`, `coordinates[]`, `distanceMeters`, `provider`.
- `Workout`: `id`, `routeId?`, `startedAt`, `endedAt`, `activeDurationSeconds`, `distanceMeters`, `averagePaceSecondsPerKm?`, `averageHeartRateBpm?`, `points[]`.
- `WorkoutPoint` include `sequence`, `recordedAt`, `coordinate` e `activeElapsedSeconds?`.
- `SyncEnvelope`: `schemaVersion`, `entityType`, `entityId`, `revision`, `createdAt`, `payload`.

Allineare DTO Swift, serializzazione WatchConnectivity e schema SQL; versionare il formato dei messaggi per compatibilità evolutiva. Non introdurre un framework di sincronizzazione generico.

## 6. Servizi e API

### Supabase

- Usare lo **stack Docker ufficiale self-hosted**, fissando una release compatibile; non ricostruire manualmente i singoli servizi.
- Configurazione locale tramite file `.env` **non versionato** e `.env.example` senza segreti.
- Migrazioni SQL versionate in Git, PostGIS installato nello schema `extensions`.
- SDK Swift su iPhone per Auth e Data API, con permessi minimi.
- Per sviluppo su dispositivi fisici, endpoint raggiungibile nella LAN e TLS valido: evitare di disabilitare indiscriminatamente App Transport Security.

### Routing

- Servizio **GraphHopper** separato nel Docker Compose, dati OSM regionali, profilo `foot` abilitato.
- Accesso al routing da iPhone **tramite funzione/backend protetto**; niente segreti e niente amministrazione del routing esposti al dispositivo.
- Operazioni concettuali:
  - `routeThroughWaypoints(start, via[], end)` → geometria, distanza, eventuali istruzioni.
  - `generateRoundTrip(start, targetDistanceMeters, seed)` → geometria, distanza e dati del percorso.
  - `generateWaypointLoop(waypoints, seed)` → anello pedonale chiuso con i waypoint scelti.
- Validare input, numero massimo waypoint, timeout ed errori di area non coperta.
- Misurare latenza, richieste di generazione e consumo del backend in aggregato, evitando coordinate nei log. Applicare gli stessi limiti operativi anti-abuso a tutti gli account. Al lancio le funzionalità Pro lavorano localmente e non alzano i limiti di routing o aumentano le richieste necessarie per generare un percorso.
- Non persistire geometrie ricavate da `MKDirections` salvo verifica specifica delle condizioni Apple; preferire geometrie prodotte da GraphHopper/OSM per ciò che si salva e condivide fra dispositivi.

### Sincronizzazione e offline

- Usare `WCSession` con le primitive adatte: **application context** per stato leggero, **file transfer** per percorsi/tracce consistenti. Non presupporre consegna immediata.
- La coda di invio deve sopravvivere alla chiusura dell'app; conferma esplicita e upload **idempotente** (`upsert`/vincoli di unicità).
- Trasferire le tracce a blocchi/file invece di inviare un messaggio per ogni punto GPS.
- Recupero da interruzioni: nessun allenamento perso e nessun duplicato dopo riavvio/ripetizione upload.
- La disponibilità di mappe offline su Watch/iPhone è **best effort** e non blocca il tracking.

### Acquisto e accesso a Runloop Pro

- Creare un solo prodotto in App Store Connect, di tipo **non consumabile**. Prezzo e disponibilità si impostano nello store. Mantenere stabile il Product ID dopo la scelta.
- Su iPhone verificare le transazioni StoreKit, leggere `Transaction.currentEntitlements` e osservare `Transaction.updates`. «Ripristina acquisti» richiama `AppStore.sync()` solo su richiesta. L'accesso dipende dall'acquisto associato all'account App Store. Supabase gestisce i dati del runner.
- Il Watch riceve tramite WatchConnectivity lo stato Pro derivato dall'ultima verifica su iPhone. Conserva questo stato per usare gli avvisi senza rete e lo aggiorna al successivo contatto con iPhone. Acquisto e ripristino si eseguono solo su iPhone.
- Prima della prima verifica positiva, rendere disponibili le funzioni gratuite. Un acquisto in attesa o annullato non sblocca Pro. Un disservizio temporaneo dello store conserva l'ultimo stato accertato. Dopo una revoca, un rimborso o un cambio dell'account App Store rilevato, applicare lo stato restituito da StoreKit e aggiornare il Watch. I percorsi già salvati, anche se importati con Pro, e tutti gli allenamenti restano consultabili, utilizzabili ed esportabili.
- Validare acquisto, ripristino e revoca con un file `.storekit` locale e poi in sandbox con il prodotto effettivo. Prima della vendita servono un Team titolare iscritto all'Apple Developer Program e la configurazione del Paid Apps Agreement, dei dati fiscali e bancari in App Store Connect.

## 7. Architettura del repository

```text
Runloop/
├── Runloop.xcodeproj/       # Progetto Xcode per iOS e watchOS
├── Apps/
│   ├── iOS/                    # SwiftUI, mappe, percorsi, storico, autenticazione
│   └── watchOS/                # SwiftUI, allenamento, mappa e sync locale
├── Packages/
│   └── RunloopCore/             # DTO Codable, unità, ID, contratti di sync
├── Backend/
│   ├── supabase/               # riferimento/config stack ufficiale, migrations
│   ├── routing/                # GraphHopper, configurazione, import regione OSM
│   └── .env.example
├── Docs/
│   └── (documenti aggiuntivi solo se servono)
├── SPEC.md
└── FEATURE.md
```

**Regola di bootstrap:** prima di inizializzare, esaminare la root esistente e preservarne il contenuto. La struttura sopra è un obiettivo logico, non un motivo per spostare o ricreare file senza necessità.

**Regole implementative:** SwiftUI nativo; codice suddiviso per feature; MVVM **leggero** dove utile, non obbligatorio; servizi piccoli per MapKit, Supabase, routing, workout e WatchConnectivity. Evitare Clean Architecture completa, DI framework, event bus, codegen complesso, microservizi non necessari e infrastrutture di test sproporzionate.

## 8. Requisiti non funzionali e verifica

- **Affidabilità:** nessuna perdita di una sessione completata per assenza di rete o chiusura temporanea dell'app.
- **Usabilità Watch:** azioni principali accessibili con pochi tap; testo leggibile durante la corsa.
- **Permessi:** spiegare il motivo di HealthKit/localizzazione al momento giusto; gestire diniego o permessi revocati.
- **Privacy:** dati privati di default, minimizzazione degli upload, possibilità di rimuovere allenamenti e account/dati secondo policy da definire per la pubblicazione.
- **Prestazioni:** evitare redraw frequenti e lavoro CPU eccessivo sul Watch; testare consumo batteria in sessione reale.
- **Sicurezza:** RLS, HTTPS al di fuori del puro ambiente locale, rotazione segreti, niente coordinate/credenziali nei log.
- **Compatibilità:** convalidare MapKit SwiftUI, HealthKit e comunicazione Watch sul modello fisico disponibile; il simulatore non sostituisce il test GPS reale.

### Criterio di accettazione MVP

Con due dispositivi fisici accoppiati, un utente crea e salva un **anello da circa 5 km** su iPhone, lo trova sul Watch, avvia un allenamento senza iPhone e senza rete, termina e salva la corsa, poi ritrova su iPhone traccia e metriche sincronizzate **una sola volta**, anche dopo un riavvio o un retry. La distanza generata può differire dal target; viene mostrata quella effettiva.

Eseguire il test senza acquisto Pro. Verificare anche un allenamento senza percorso salvato sul Watch, la consultazione locale prima del login e l'esportazione della propria traccia.

### Criterio di accettazione del rilascio Pro

Un acquisto sandbox verificato sblocca le tre funzioni previste. Dopo reinstallazione l'iPhone recupera l'acquisto, con ripristino manuale se necessario. Il Watch già sincronizzato segnala uno scostamento reale senza iPhone e rete. Dopo revoca o rimborso, fino al successivo aggiornamento un dispositivo offline usa l'ultimo stato disponibile. Ricevuto l'aggiornamento, lo sblocco termina e i percorsi e gli allenamenti già creati restano disponibili.

## 9. Decisioni aperte, limitate al necessario

1. **Hardware pilota:** versioni iPhone/Apple Watch disponibili e disponibilità effettiva di iOS/watchOS 26.
2. **Copertura OSM iniziale:** scegliere una regione ridotta per import e test GraphHopper; estenderla solo dopo il MVP.
3. **Hosting:** Docker locale per sviluppo; server HTTPS raggiungibile solo quando si avviano test end-to-end fuori LAN/pubblicazione.
4. **Aspetti legali:** verificare l'uso delle geometrie e attribuzioni OSM/GraphHopper/Apple prima del rilascio esterno.
5. **Rilascio commerciale:** scegliere prezzo e mercati iniziali dopo il pilota e la verifica dei costi operativi. Verificare il Team di distribuzione, la configurazione in App Store Connect e la disponibilità di un prodotto sandbox prima di preparare il rilascio pubblico.

## 10. Riferimenti ufficiali

- [MapKit for SwiftUI](https://developer.apple.com/documentation/mapkit/mapkit-for-swiftui)
- [watchOS 26: novità MapKit](https://developer.apple.com/videos/play/wwdc2025/334/)
- [Apple Maps — Developer Program License Agreement](https://developer.apple.com/support/terms/)
- [Apple HealthKit: running workout sessions](https://developer.apple.com/documentation/healthkit/running-workout-sessions)
- [Apple: building a multidevice workout app](https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app)
- [Supabase self-hosting con Docker](https://supabase.com/docs/guides/self-hosting/docker)
- [Supabase SDK Swift](https://supabase.com/docs/reference/swift/installing)
- [Supabase PostGIS](https://supabase.com/docs/guides/database/extensions/postgis)
- [GraphHopper routing engine](https://github.com/graphhopper/graphhopper)
- [GraphHopper routing API e round_trip](https://github.com/graphhopper/graphhopper/blob/master/docs/web/api-doc.md)
- [Apple: configurare gli acquisti in-app](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases/)
- [Apple: Transaction.currentEntitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements)
- [Apple: AppStore.sync()](https://developer.apple.com/documentation/storekit/appstore/sync%28%29)
- [Apple: testare gli acquisti in Xcode e in sandbox](https://developer.apple.com/documentation/storekit/testing-at-all-stages-of-development-with-xcode-and-the-sandbox)
- [Apple: iscrizione all'Apple Developer Program](https://developer.apple.com/help/account/membership/program-enrollment/)
- [Apple: inviare il primo acquisto in-app per la revisione](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase)
