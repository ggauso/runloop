"""Run real outage/reconnect tests on a dedicated, signed-in pair with a route on the Watch.

Example (from the repo):
  RUNLOOP_TEST_PAIR=<pair UUID> python3 Tests/AppStates/recovery.py servizio Watch /tmp/service-watch
  RUNLOOP_TEST_PAIR=<pair UUID> python3 Tests/AppStates/recovery.py compagno Watch /tmp/peer-watch

The service scenario temporarily stops the local Runloop GraphHopper container. Set
RUNLOOP_DOCKER_CONTEXT if it is not in colima. Each run needs its own output directory.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Loop5K"))
from paired_loop import Loop, PHONE_APP, boot, command, container, sim, wait_for


def run(args):
    if not os.getenv("RUNLOOP_TEST_PAIR"):
        raise ValueError("Seleziona la coppia di prova con RUNLOOP_TEST_PAIR.")
    peer = args.scenario == "compagno"
    watch = args.device == "Watch"
    if peer and not watch:
        raise ValueError("La prova con iPhone spento si esegue su Watch.")
    args.output.mkdir(parents=True, exist_ok=False)
    pair = Loop(args.output)
    scheme = "LoopWatchUI" if watch else "LoopPhoneUI"
    device = pair.watch if watch else pair.phone
    method = "testCompanionRecovery" if peer else "testRouteServiceRecovery"
    tag = uuid.uuid4().hex
    boot(pair.phone)
    boot(pair.watch)
    pair.build_tests(scheme, device)
    if watch:
        pair.build_tests("LoopPhoneUI", pair.phone)
        sim("install", pair.phone, pair.products / "Debug-iphonesimulator/Runloop.app")
        sim("launch", pair.phone, PHONE_APP)

    def docker(*args):
        return command("docker", "--context", os.getenv("RUNLOOP_DOCKER_CONTEXT", "colima"), *args)

    provider = "runloop-graphhopper-1"
    def healthy():
        return docker("inspect", "-f", "{{.State.Health.Status}}", provider) == "healthy"

    def launch_phone():
        result = subprocess.run(["xcrun", "simctl", "launch", pair.phone, PHONE_APP], capture_output=True)
        return result.returncode == 0

    def restore():
        if peer:
            boot(pair.phone)
            wait_for("Apertura di Runloop dopo il riavvio", launch_phone, 45)
        else:
            docker("start", provider)
            wait_for("GraphHopper disponibile", healthy, 120)

    if not peer and not healthy():
        raise RuntimeError("Il servizio percorsi locale deve essere disponibile all'inizio della prova.")
    restored = False
    try:
        if peer:
            sim("shutdown", pair.phone)
        else:
            docker("stop", "--time", "3", provider)
        with pair.phase(scheme, device, method, test_class="AppStateTests", RUNLOOP_QA_CASE=tag) as test:
            def offline_marker():
                try:
                    cache = container(device, "com.luigiausino.runloop." + scheme + ".xctrunner") / "Library/Caches"
                except subprocess.CalledProcessError:
                    return None
                return cache if (cache / (tag + "-offline")).exists() else None
            cache = wait_for("Errore offline visibile", offline_marker, 170, test)
            restore()
            restored = True
            (cache / (tag + "-online")).touch()
    finally:
        if not restored:
            restore()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scenario", choices=["servizio", "compagno"])
    parser.add_argument("device", choices=["iPhone", "Watch"])
    parser.add_argument("output", type=Path)
    run(parser.parse_args())
