# Routing Runloop

La prova locale usa [GraphHopper 10.2](https://github.com/graphhopper/graphhopper/tree/10.2), Java 17 e un [estratto Geofabrik di Monaco](https://download.geofabrik.de/europe/monaco/). L'estratto è piccolo e adatto alla verifica tecnica. La copertura del pilota resta da scegliere. Avviare dalla root di Runloop.

```sh
routing_config="$PWD/Backend/routing/graphhopper.yml"
routing_workdir="$(mktemp -d -t runloop-routing)"
cd "$routing_workdir"
curl -fLO https://repo.maven.apache.org/maven2/com/graphhopper/graphhopper-web/10.2/graphhopper-web-10.2.jar
curl -fLO https://download.geofabrik.de/europe/monaco-latest.osm.pbf
java -Xmx512m -Ddw.graphhopper.datareader.file=monaco-latest.osm.pbf \
  -jar graphhopper-web-10.2.jar server "$routing_config"
```

Da un secondo terminale si possono ripetere un itinerario a tre punti e una richiesta ad anello.

```sh
curl -fsSG http://127.0.0.1:18989/route \
  --data 'profile=foot' --data 'points_encoded=false' --data 'instructions=false' \
  --data 'point=43.7343,7.4204' --data 'point=43.7373,7.4242' --data 'point=43.7401,7.4274'
curl -fsSG http://127.0.0.1:18989/route \
  --data 'profile=foot' --data 'points_encoded=false' --data 'instructions=false' \
  --data 'point=43.7358,7.4236' --data 'algorithm=round_trip' \
  --data 'round_trip.distance=5000' --data 'round_trip.seed=11'
```

Le richieste usano `lat,lon`. `paths[0].points` è una `LineString` GeoJSON con coppie `[lon, lat]`; per MapKit assegnare l'elemento 1 a `latitude` e lo 0 a `longitude`. `paths[0].distance` è la distanza effettiva in metri. Il risultato può cambiare con l'estratto. L'anello usa il profilo `foot` in modalità flessibile e ha un limite ai nodi visitati.

## Avvio con Supabase

Dopo aver applicato la [migrazione dello schema Runloop](../../README.md#schema-runloop), eseguire dalla root del repository.

```sh
mkdir -p Backend/routing/data
curl -fLo Backend/routing/data/region.osm.pbf \
  https://download.geofabrik.de/europe/monaco-latest.osm.pbf
cd Backend/supabase
docker compose exec -T db psql -X -U postgres -v ON_ERROR_STOP=1 \
  < migrations/20261124210000_routing_quota.sql
docker compose -f docker-compose.yml -f ../routing/docker-compose.routing.yml \
  up -d --build --wait auth rest functions
```

Applicare la migrazione della quota una volta per database. Per un altro estratto impostare `RUNLOOP_OSM_FILE` con un percorso locale, assoluto o relativo a `Backend/supabase`. Il grafo viene ricostruito quando cambia il contenuto dell'estratto o la configurazione. Il container GraphHopper è raggiungibile nella rete Compose. L'override di sviluppo pubblica il gateway Supabase su `127.0.0.1` salvo configurazione esplicita.

### API di routing

Inviare `POST /functions/v1/routing` con `Content-Type: application/json`, `apikey` pubblicabile e `Authorization: Bearer <access_token>` della sessione utente. Gli identificativi di chiavi e token hanno ruoli diversi. Il client usa la propria sessione Supabase.

```json
{"mode":"manual","waypoints":[{"latitude":43.7343,"longitude":7.4204},{"latitude":43.7373,"longitude":7.4242},{"latitude":43.7401,"longitude":7.4274}]}
```

```json
{"mode":"round_trip","start":{"latitude":43.7358,"longitude":7.4236},"targetDistanceMeters":5000,"seed":11}
```

```json
{"mode":"waypoint_loop","waypoints":[{"latitude":43.7358,"longitude":7.4236},{"latitude":43.7344,"longitude":7.4220}],"seed":0}
```

`manual` e `waypoint_loop` accettano da 2 a 25 punti. In `waypoint_loop` l'itinerario visita i punti nell'ordine scelto e torna alla partenza cercando un ritorno distinto. Il server prova fino a tre rientri per richiesta entro lo stesso timeout. `round_trip` accetta da 500 a 50.000 metri interi e le due modalità ad anello accettano un `seed` intero da 0 a 2.147.483.647. La risposta contiene `provider`, `distanceMeters` e `geometry` come `LineString` GeoJSON. Una coordinata non valida produce `400`, una sessione assente o non valida `401`, una traccia non disponibile `422` e una quota esaurita `429`. Le richieste valide consumano una quota per utente di 12 al minuto, uguale per accesso gratuito e Pro.

I log della funzione contengono stato HTTP e durata per misurare volumi ed errori. Le coordinate delle richieste non sono registrate nel gateway o nei log del servizio di routing. Il test SQL della quota è in [Backend/supabase/tests](../supabase/tests/runloop_routing_quota.sql).

## Attribuzione e persistenza

Conservare `provider` insieme alla geometria. Mostrare «© OpenStreetMap contributors» con il link di attribuzione nella vista dei percorsi di origine OSM e mantenere il credito quando si esporta una geometria di quella fonte. Rivedere la licenza prima di distribuire un database di tracce o il grafo. Usare MapKit per lo sfondo e rispettare le condizioni Apple per qualsiasi geometria ottenuta da `MKDirections`. [Attribuzione OSM](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines) · [Licenza e copyright OSM](https://www.openstreetmap.org/copyright) · [Condizioni Apple Developer](https://developer.apple.com/support/terms/)
