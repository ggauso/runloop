# Runloop

App SwiftUI per iOS 26 e watchOS 26. Si può registrare una corsa outdoor con iPhone o Watch. Scegliere «Corsa libera» oppure aprire un percorso e toccare «Inizia corsa». Il dispositivo scelto registra GPS e tempo attivo e salva il risultato. Aprendo Runloop sul compagno raggiungibile si può seguire e controllare la stessa corsa. Sul telefono sono disponibili storico completo, cloud e GPX. Il Watch conserva i percorsi scaricati, le corse locali e fino a 20 riepiloghi ricevuti dall’iPhone. `Packages/RunloopCore` contiene i contratti condivisi.

Per usare il sensore cardiaco del Watch, avvia la corsa al polso oppure apri Runloop su entrambi e scegli **Usa Apple Watch** dall’iPhone. Durante la corsa tocca **Battito** per impostare la tua FC massima e, se vuoi, una zona obiettivo. Su iPhone trovi la stessa impostazione in **Account → Preferenze → Zone cardiache**. Con **Termina → Salva corsa** ritrovi l’attività nello storico. **Termina → Scarta senza salvare → Scarta corsa** abbandona la registrazione e rimuove la traccia temporanea.

I due target usano la firma automatica con il Personal Team `UTZ3WTZ42X`. Il bundle ID iPhone `com.luigiausino.runloop` è definito in `RUNLOOP_IOS_BUNDLE_IDENTIFIER`. Il target Watch aggiunge `.watchkitapp` e usa il bundle ID iPhone come `WKCompanionAppBundleIdentifier`. Per una build firmata di sviluppo, collegare un dispositivo e selezionarlo in Xcode così che possa registrarlo e creare il profilo.

Per compilare sui simulatori:

```sh
xcodebuild -project Runloop.xcodeproj -scheme Runloop -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Runloop.xcodeproj -scheme 'Runloop Watch' -destination 'generic/platform=watchOS Simulator' build
swift test --package-path Packages/RunloopCore
```

Per la prova di coppia, aprire `Runloop.xcodeproj`, scegliere un simulatore iPhone abbinato a un simulatore Apple Watch e avviare Runloop su entrambi. I simulatori usano messaggi interattivi WatchConnectivity. Le build per hardware consegnano i file in background e inviano una conferma dopo il salvataggio. Il collaudo hardware è in [F-501](./FEATURE.md#f-501--eseguire-test-end-to-end-su-dispositivi-reali).

Per provare «La mia posizione» con il servizio locale di Torino, impostare Corso Luigi Einaudi 63 sui simulatori già avviati. Usare gli identificativi della coppia elencati da `xcrun simctl list pairs`.

```sh
xcrun simctl location ID_IPHONE_SIMULATO set 45.0609793,7.6585835
xcrun simctl location ID_WATCH_SIMULATO set 45.0609793,7.6585835
```

## Test Xcode dell’anello da 5 km

Aprire lo schema **Anello 5 km**, selezionare **My Mac** e premere **⌘U**. Il Mac coordina le due prove di interfaccia sulla coppia attiva di simulatori Xcode. Durante la registrazione il test spegne il simulatore iPhone e lo riaccende per verificare la consegna. Usare una coppia dedicata alle prove.

Prima della prima esecuzione, avviare Supabase e il servizio percorsi locale con la copertura di Torino, accedere all’account di sviluppo nell’app iPhone e autorizzare Runloop in Salute sul Watch simulato. Il test imposta la posizione di partenza a Torino e crea un nuovo percorso con un nome univoco. La corsa salvata resta consultabile nell’account di prova.

Il registratore del Watch segue realmente nel tempo la geometria ricevuta, con posizioni simulate a 12 m/s e una pausa. Un giro di 5 km richiede circa sette minuti di movimento, oltre ai tempi di build e riavvio dei simulatori. Nel risultato XCTest si trovano il GPX creato dal pulsante «Esporta GPX», il confronto dei tempi e il numero di copie della corsa nello storico iPhone.

Lo stesso test si può avviare da terminale.

```sh
xcodebuild -project Runloop.xcodeproj -scheme 'Anello 5 km' \
  -destination 'platform=macOS' -parallel-testing-enabled NO test
```

## Supabase locale

Stack ufficiale Supabase `docker/`, fissato al commit `6205145edd7d94c6b1e37437c873df7d0b5b9d3d`. Richiede Docker Compose, OpenSSL e le dipendenze indicate dalla documentazione ufficiale inclusa. Solo sviluppo locale: la configurazione upstream pubblica porte sull'host, limitarne l'accesso prima di collegarsi a reti non fidate.

```sh
cd Backend/supabase
cp -n .env.example .env
sh utils/generate-keys.sh --update-env
sh utils/add-new-auth-keys.sh --update-env
docker compose up -d
docker compose ps
docker compose logs -f
docker compose down
```

Eseguire la generazione delle chiavi solo alla prima configurazione: non rigenerarle su un database già utilizzato. Le utility mostrano segreti sul terminale: non condividerli né versionare `.env`. Per eliminare anche i dati locali, dopo aver verificato che non servano, leggere prima il contenuto di `reset.sh`, quindi eseguire `sh reset.sh` dalla cartella `Backend/supabase`. Non usare queste credenziali o questa configurazione per un deployment pubblico.

In caso di disco Docker pieno, confrontare `colima list` con `colima ssh -- df -h /var/lib/docker`: il valore configurato può differire dal filesystem effettivo. Il precedente database incompleto è conservato in `volumes/db/data.failed-20261112` e il precedente volume `supabase_db-config` è stato mantenuto.

Con Colima e repository su disco esterno, verificare che i file della workspace siano visibili anche nella VM. Per questa workspace, con Colima fermo, avviare con `colima start --mount "$HOME:w" --mount /Volumes/DiscoE/Runloop:w`. Senza il mount, Docker può creare cartelle nella VM al posto dei file SQL bind-mounted e avviare un database diverso da quello sul disco.

### Schema Runloop

Per inizializzare lo schema dell'app su un nuovo database Supabase, eseguire dalla root del repository dopo l'avvio di `db` e `auth`.

```sh
cd Backend/supabase
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < migrations/20261124200000_runloop_core.sql
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < migrations/20261124213000_route_revision.sql
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < migrations/20261124220000_workout_upload.sql
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < migrations/20261124221000_workout_deletion.sql
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < migrations/20261125120000_waypoint_loops.sql
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < tests/runloop_core_rls.sql
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < tests/runloop_workout_upload.sql
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < tests/runloop_route_revision.sql
```

Le migrazioni si applicano una volta per database. Configurano PostGIS, l'isolamento per account, le revisioni dei percorsi e l'upload e cancellazione idempotenti delle corse. I test usano utenti fittizi e fanno rollback al termine. I client inviano lo UUID generato all'origine per percorsi e allenamenti. Le coordinate GeoJSON usano l'ordine `[lon, lat]`.

Per avviare GraphHopper con Supabase e provare l'endpoint autenticato, seguire la [guida di routing](./Backend/routing/README.md#avvio-con-supabase).

### Accesso dal simulatore iPhone

Debug usa `http://127.0.0.1:8000`. Creare `Apps/iOS/Configuration/Local.xcconfig` e impostare `RUNLOOP_SUPABASE_PUBLIC_KEY` al valore pubblico `SUPABASE_PUBLISHABLE_KEY` del progetto Supabase oppure alla chiave anonima compatibile. Il file locale è ignorato da Git. Per provare il ripristino della sessione, lasciare a Xcode la firma ad hoc del simulatore, necessaria al Portachiavi.

Per verificare le email di registrazione senza inviarle all'esterno, avviare l'override di posta dalla cartella `Backend/supabase`.

```sh
docker compose -f docker-compose.yml -f ../routing/docker-compose.routing.yml \
  -f dev/docker-compose.runloop-mail.yml up -d --wait auth rest functions
```

Aprire la [casella locale](http://127.0.0.1:12580), scegliere l'indirizzo di prova e seguire il link di conferma prima di accedere. Per un endpoint esterno impostare via build settings `RUNLOOP_SUPABASE_SCHEME=https`, `RUNLOOP_SUPABASE_AUTHORITY` e `RUNLOOP_SUPABASE_PUBLIC_KEY`. L'app accetta HTTP solo per il loopback nel simulatore Debug.

### Dati delle corse

La sincronizzazione invia date, durata attiva, distanza, passo medio, eventuale percorso associato e punti GPS con orari, tempo attivo e velocità disponibili. Le corse registrate prima dell’accesso restano sul dispositivo finché l’utente sceglie di associarle al proprio account. La frequenza cardiaca media è facoltativa e si attiva in *Account*. Disattivarla esclude la media dalle prossime sincronizzazioni. L’accesso ai dati di Salute si può revocare dalle autorizzazioni di Salute.

L’eliminazione da Runloop rimuove la copia iPhone e i dati sincronizzati, se presenti, e raggiunge il Watch al successivo contatto. La copia in Salute si gestisce da Salute. L’export GPX viene creato su richiesta e contiene le coordinate selezionate e gli orari disponibili per una corsa. I dati sanitari restano fuori dal file.
