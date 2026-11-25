FROM eclipse-temurin:17-jre-jammy

WORKDIR /opt/graphhopper
ADD https://repo.maven.apache.org/maven2/com/graphhopper/graphhopper-web/10.2/graphhopper-web-10.2.jar graphhopper.jar
COPY graphhopper.yml start.sh ./
RUN printf '%s  graphhopper.jar\n' ead763749c395ea0cc45b3fd10092d6de84d62fb5cbaf7d416ba6cc142c5716c | sha256sum -c - \
    && chmod 0444 graphhopper.jar \
    && mkdir -p /var/lib/runloop/graph \
    && chown 10001:10001 /var/lib/runloop/graph

USER 10001:10001
ENTRYPOINT ["/bin/sh", "/opt/graphhopper/start.sh"]
