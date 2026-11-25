#!/bin/sh
set -eu

osm_file=/var/lib/runloop/region.osm.pbf
if [ ! -s "$osm_file" ]; then
    echo 'Extract .osm.pbf mancante o vuoto' >&2
    exit 1
fi

extract_hash=$(sha256sum "$osm_file")
config_hash=$(sha256sum graphhopper.yml)
cache_dir="/var/lib/runloop/graph/v10.2-${extract_hash%% *}-${config_hash%% *}"

exec java -Xmx"${RUNLOOP_ROUTING_MAX_HEAP:-512m}" \
    '-Ddw.server.application_connectors[0].bind_host=0.0.0.0' \
    -Ddw.graphhopper.datareader.file="$osm_file" \
    -Ddw.graphhopper.graph.location="$cache_dir" \
    -jar graphhopper.jar server graphhopper.yml
