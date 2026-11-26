"""Host side of the Xcode paired-simulator test. Only reads app archives; drives the app via XCTest."""
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PHONE_APP = "com.luigiausino.runloop"
WATCH_APP = PHONE_APP + ".watchkitapp"
SPEED = 12.0  # m/s, below the recorder's 14 m/s plausibility limit.
START = "45.0609793,7.6585835"
APPLE_EPOCH = 978307200


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def command(*args, **kwargs):
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs).strip()


def sim(*args):
    return command("xcrun", "simctl", *args)


def boot(device):
    devices = json.loads(sim("list", "devices", "-j"))["devices"]
    state = next(d["state"] for group in devices.values() for d in group if d["udid"] == device)
    if state == "Shutdown":
        sim("boot", device)
    sim("bootstatus", device, "-b")


def pair():
    pairs = json.loads(sim("list", "pairs", "-j"))["pairs"]
    selected = os.getenv("RUNLOOP_TEST_PAIR")
    if selected:
        check(selected in pairs, "Coppia di simulatori sconosciuta: " + selected)
        return pairs[selected]
    active = [p for p in pairs.values() if "active," in p["state"]]
    check(len(active) == 1, "Selezionare una coppia con RUNLOOP_TEST_PAIR.")
    return active[0]


def wait_for(description, probe, timeout, process=None):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        result = probe()
        if result:
            return result
        if process and process.poll() is not None:
            raise RuntimeError(f"Fase XCTest terminata prima di {description} (exit {process.returncode}).")
        time.sleep(0.5)
    raise TimeoutError(description)


def container(device, bundle):
    return Path(command("xcrun", "simctl", "get_app_container", device, bundle, "data", stderr=subprocess.PIPE))


def support(device, bundle):
    return container(device, bundle) / "Library/Application Support/Runloop"


def data(file):
    return json.loads(file.read_bytes())


def log(message):
    print(message, flush=True)


class Loop:
    def __init__(self, output):
        self.output = output
        self.case = "Loop5K-" + uuid.uuid4().hex[:12]
        selected = pair()
        self.phone = selected["phone"]["udid"]
        self.watch = selected["watch"]["udid"]
        cache = Path.home() / "Library/Caches/RunloopTests" / hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]
        self.build = Path(os.getenv("RUNLOOP_TEST_BUILD", cache))
        self.products = self.build / "Build/Products"

    def build_tests(self, scheme, device):
        log("Compilazione " + scheme)
        with (self.output / (scheme + "-build.log")).open("w") as out:
            subprocess.run(["xcodebuild", "-project", str(ROOT / "Runloop.xcodeproj"), "-scheme", scheme,
                            "-destination", "id=" + device, "-derivedDataPath", str(self.build),
                            "-disableAutomaticPackageResolution", "build-for-testing"],
                           stdout=out, stderr=subprocess.STDOUT, check=True)

    @contextlib.contextmanager
    def phase(self, scheme, device, method, *, test_class="LoopUITests", **params):
        variants = list(self.products.glob(scheme + "_*.xctestrun"))
        check(bool(variants), "Manca il prodotto di test " + scheme)
        template = max(variants, key=lambda p: p.stat().st_mtime)
        plan = plistlib.loads(template.read_bytes())
        targets = [target for conf in plan.get("TestConfigurations", []) for target in conf["TestTargets"]]
        if not targets:
            targets = [v for k, v in plan.items() if k == scheme]
        check(len(targets) == 1, "Configurazione XCTest inattesa per " + scheme)
        targets[0].setdefault("EnvironmentVariables", {}).update(LOOP_CASE=self.case, **params)
        # __TESTROOT__ is resolved relative to the .xctestrun file.
        with tempfile.NamedTemporaryFile(dir=self.products, suffix=".xctestrun") as patched:
            plistlib.dump(plan, patched); patched.flush()
            log("XCTest " + method)
            path = self.output / (method + ".log")
            with path.open("w") as out:
                p = subprocess.Popen(["xcodebuild", "-xctestrun", patched.name, "-destination", "id=" + device,
                                      "-parallel-testing-enabled", "NO", "-only-testing:" + scheme + "/" + test_class + "/" + method,
                                      "-resultBundlePath", str(self.output / (method + ".xcresult")), "test-without-building"],
                                     stdout=out, stderr=subprocess.STDOUT)
                try:
                    yield p
                    check(p.wait(timeout=160) == 0, "Prova fallita: " + method)
                except BaseException:
                    if p.poll() is None:
                        p.terminate()
                        try:
                            p.wait(timeout=15)
                        except subprocess.TimeoutExpired:
                            p.kill(); p.wait()
                    log(path.read_text(errors="replace")[-5000:])
                    raise

    def watch_route(self):
        files = (support(self.watch, WATCH_APP) / "Routes").glob("*/*.json")
        return next((r for r in map(data, files) if r["payload"]["name"] == self.case), None)

    def mailbox(self, device, scheme):
        bundle = f"com.luigiausino.runloop.{scheme}.xctrunner"
        return container(device, bundle) / "Library/Caches" / self.case

    def signal_box(self, device, scheme, marker, process, timeout):
        def locate():
            try:
                box = self.mailbox(device, scheme)
            except subprocess.CalledProcessError:
                return None
            return box if (box / marker).exists() else None
        return wait_for(marker, locate, timeout, process)

    def discard_interrupted(self):
        current = support(self.watch, WATCH_APP) / "current-workout.json"
        if current.exists() and (data(current).get("route") or {}).get("payload", {}).get("name") == self.case:
            expected = data(current)["id"]
            with self.phase("LoopWatchUI", self.watch, "testDiscardInterruptedTestRun") as test:
                box = self.signal_box(self.watch, "LoopWatchUI", "discard-request", test, 40)
                active = data(support(self.watch, WATCH_APP) / "current-workout.json")
                check(active["id"] == expected and active["route"]["payload"]["name"] == self.case, "Corsa di prova cambiata.")
                (box / "owned").touch()

    def prepare(self):
        log(f"{self.case} · iPhone {self.phone} · Watch {self.watch}")
        for device in (self.phone, self.watch):
            boot(device)
        for device, bundle in [(self.phone, PHONE_APP), (self.watch, WATCH_APP)]:
            try:
                root = support(device, bundle)
            except subprocess.CalledProcessError:
                continue  # First install on this simulator.
            check(not (root / "current-workout.json").exists(), "Una corsa è già aperta sul simulatore.")
        self.build_tests("LoopPhoneUI", self.phone)
        self.build_tests("LoopWatchUI", self.watch)
        for device, bundle, app in [(self.watch, WATCH_APP, "Debug-watchsimulator/Runloop Watch.app"),
                                    (self.phone, PHONE_APP, "Debug-iphonesimulator/Runloop.app")]:
            sim("install", device, self.products / app)
            sim("privacy", device, "grant", "location", bundle)
            sim("location", device, "set", START)
        sim("launch", self.watch, WATCH_APP)
        with self.phase("LoopPhoneUI", self.phone, "testCreateAndSend"):
            pass
        envelope = self.watch_route()
        check(envelope is not None, "Percorso inviato assente dal Watch.")
        route = envelope["payload"]
        check(route["mode"] == "round_trip" and route["targetDistanceMeters"] == 5000, "Obiettivo diverso da 5 km.")
        check(4500 <= route["distanceMeters"] <= 5500, "Anello fuori dalla tolleranza del 10%.")
        log(f"Percorso {envelope['entityID']}: {route['distanceMeters']:.1f} m, ricevuto al polso.")
        return envelope

    def record(self, envelope):
        route = envelope["payload"]
        coordinates = route["geometry"]["coordinates"]
        check(metres(coordinates[0], coordinates[-1]) < 20, "Il percorso generato è aperto.")
        with self.phase("LoopWatchUI", self.watch, "testRecordOffline") as test:
            box = self.signal_box(self.watch, "LoopWatchUI", "ready", test, 110)
            phone_root = support(self.phone, PHONE_APP)
            sim("shutdown", self.phone)
            log("iPhone spento. Registrazione autonoma sul Watch.")
            (box / "offline").touch()
            wait_for("pausa sul Watch", (box / "paused").exists, 80, test)
            time.sleep(6)
            (box / "resume").touch()
            wait_for("ripresa sul Watch", (box / "running").exists, 30, test)
            watch_root = support(self.watch, WATCH_APP)
            current = data(watch_root / "current-workout.json")
            workout_id = current["id"]
            folder = watch_root / "Workouts" / workout_id
            self.drive(coordinates, folder / "points.jsonl", test)
            (box / "arrived").touch()
        workout = data(folder / "workout.json")
        check(workout["id"] == workout_id and workout.get("source") == "watch", "Registratore inatteso.")
        check(workout.get("routeID") == envelope["entityID"] and workout.get("ownerID") == route["ownerID"],
              "Percorso o account diverso da quello trasferito.")
        check(workout.get("plannedRoute") == route["geometry"], "Geometria pianificata diversa al salvataggio.")
        check(not (folder / "received.json").exists(), "Ricevuta presente con iPhone spento.")
        check(not self.history_files(phone_root, envelope), "Corsa già presente sull’iPhone spento.")
        active = workout["activeDurationSeconds"]
        paused = float((box / "running").read_text()) - float((box / "paused").read_text())
        independent = float((box / "final-pause").read_text()) - (APPLE_EPOCH + workout["startedAt"]) - paused
        check(paused >= 6 and abs(independent - active) <= 5, f"Tempo attivo {active:.2f}s, misurato {independent:.2f}s.")
        check(abs(clock_seconds((box / "watch-time").read_text()) - active) <= 1.1, "Timer Watch incoerente.")
        verify_trace(workout, coordinates)
        log(f"Salvataggio offline: {workout_id}, {active:.2f} s attivi, {len(workout['points'])} punti.")
        return workout, folder, independent

    def drive(self, coordinates, journal, process):
        length = polyline_length(coordinates)
        waypoints = "\n".join(f"{lat},{lon}" for lon, lat in coordinates) + "\n"
        sim_args = ["xcrun", "simctl", "location", self.watch, "start", f"--speed={SPEED}", "--interval=1", "-"]
        subprocess.run(sim_args, input=waypoints, text=True, check=True)
        last_bucket = -1

        def finished():
            nonlocal last_bucket
            if not journal.exists():
                return False
            # The recorder appends whole JSON lines. A partial final line is still being written.
            rows = [json.loads(line) for line in journal.read_bytes().split(b'\n')[:-1] if line]
            if not rows:
                return False
            points = [xy(row) for row in rows]
            covered = polyline_length(points)
            bucket = int(covered / 1000)
            if bucket > last_bucket:
                log(f"GPS al polso: {covered:.0f} / {length:.0f} m")
                last_bucket = bucket
            return covered > 0.96 * length and metres(points[-1], coordinates[-1]) <= 14

        wait_for("completamento del giro GPS simulato", finished, length / SPEED * 1.4 + 45, process)
        sim("location", self.watch, "set", f"{coordinates[-1][1]},{coordinates[-1][0]}")

    @staticmethod
    def history_files(phone_root, envelope):
        return [w for w in map(data, (phone_root / "Workouts" / envelope["payload"]["ownerID"]).glob("*.json"))
                if w.get("routeID") == envelope["entityID"]]

    def reconnect(self, envelope, workout, folder):
        log("Riaccendo l’iPhone e verifico la consegna e la ricevuta.")
        boot(self.phone)
        sim("launch", self.phone, PHONE_APP)
        sim("launch", self.watch, WATCH_APP)
        receipt = wait_for("ricevuta Watch dopo la riconnessione", lambda: (folder / "received.json").exists(), 100)
        check(receipt and data(folder / "received.json")["workoutID"] == workout["id"], "Ricevuta per una corsa diversa.")
        phone_root = support(self.phone, PHONE_APP)
        check(self.history_files(phone_root, envelope) == [workout], "Lo storico non contiene una sola copia identica del Watch.")
        # Reopening the app also reloads the history from disk and merges any cloud copy.
        previous = {p.relative_to(phone_root.parents[2]) for p in (phone_root.parents[2] / "tmp").rglob("*.gpx")}
        with self.phase("LoopPhoneUI", self.phone, "testHistoryAndExport", LOOP_WORKOUT=workout["id"]) as test:
            box = self.signal_box(self.phone, "LoopPhoneUI", "exporting", test, 90)
            phone_data = container(self.phone, PHONE_APP)
            files = {p for p in (phone_data / "tmp").rglob("*.gpx") if p.relative_to(phone_data) not in previous}
            check(len(files) == 1, "Atteso un solo nuovo GPX generato dal foglio di condivisione.")
            gpx = self.output / "corsa.gpx"
            shutil.copyfile(files.pop(), gpx)
            (box / "copied").touch()
            history_time = clock_seconds((box / "history-time").read_text())
            check(abs(history_time - workout["activeDurationSeconds"]) <= 1.1, "Durata visualizzata nello storico errata.")
            verify_gpx(gpx, workout["points"])
        check(self.history_files(support(self.phone, PHONE_APP), envelope) == [workout], "Copia duplicata o modificata dopo la riapertura.")
        return history_time


def xy(row):
    return [row["coordinate"]["longitude"], row["coordinate"]["latitude"]]


def metres(a, b):
    lon1, lat1, lon2, lat2 = map(math.radians, (*a, *b))
    h = math.sin((lat2-lat1)/2)**2 + math.cos(lat1)*math.cos(lat2)*math.sin((lon2-lon1)/2)**2
    return 12742000 * math.asin(min(1, math.sqrt(h)))


def polyline_length(points):
    return sum(metres(a, b) for a, b in zip(points, points[1:]))


def clock_seconds(label):
    match = re.search(r"(?<!\d)\d{1,3}:\d\d(?::\d\d)?(?!\d)", label)
    check(match, f"Tempo non leggibile nell’interfaccia: {label!r}")
    value = 0
    for component in match.group().split(":"):
        value = 60 * value + int(component)
    return value


def verify_trace(workout, planned):
    rows = workout["points"]
    points = [xy(row) for row in rows]
    length = polyline_length(planned)
    check(len(points) >= 100 and abs(polyline_length(points) - length) < 0.05 * length, "Traccia GPS incompleta.")
    check(abs(workout["distanceMeters"] - length) < 0.06 * length, "Distanza nello storico fuori tolleranza.")
    check(metres(points[0], planned[0]) <= 35 and metres(points[-1], planned[-1]) <= 35, "Estremi GPS errati.")
    # Each planned vertex must be visited in order. This also detects a reversed or truncated loop.
    cursor = 0
    for vertex in planned:
        while cursor < len(points) and metres(points[cursor], vertex) > 35:
            cursor += 1
        check(cursor < len(points), f"Vertice pianificato non raggiunto in ordine: {vertex}")
    check([r["sequence"] for r in rows] == list(range(len(rows))), "Sequenza GPS discontinua.")
    for a, b in zip(rows, rows[1:]):
        check(a["recordedAt"] < b["recordedAt"] and a["activeElapsedSeconds"] <= b["activeElapsedSeconds"],
              "Tempi GPS non ordinati.")
    check(0 <= rows[0]["activeElapsedSeconds"] <= rows[-1]["activeElapsedSeconds"] <= workout["activeDurationSeconds"] + 1,
          "Campioni al di fuori del tempo attivo.")


def verify_gpx(path, rows):
    ns = "{http://www.topografix.com/GPX/1/1}"
    root = ET.parse(path).getroot()
    check(root.tag == ns + "gpx" and root.get("version") == "1.1", "Formato GPX errato.")
    points = root.findall(f"{ns}trk/{ns}trkseg/{ns}trkpt")
    check(len(points) == len(rows), "Conteggio dei punti GPX diverso dal Watch.")
    for node, row in zip(points, rows):
        lon, lat = xy(row)
        check(abs(float(node.attrib["lat"])-lat) <= 1e-8 and abs(float(node.attrib["lon"])-lon) <= 1e-8,
              "Coordinate GPX diverse dal Watch.")
        stamp = dt.datetime.fromisoformat(node.findtext(ns + "time").replace("Z", "+00:00")).timestamp()
        check(abs(stamp - (APPLE_EPOCH + row["recordedAt"])) <= 0.002, "Timestamp GPX diverso dal Watch.")


def run(loop):
    try:
        route = loop.prepare()
        workout, folder, measured = loop.record(route)
        seconds = loop.reconnect(route, workout, folder)
        summary = dict(scenario=loop.case, percorso=route["entityID"], allenamento=workout["id"],
                       metriPrevisti=route["payload"]["distanceMeters"], metriRegistrati=workout["distanceMeters"],
                       secondiAttivi=workout["activeDurationSeconds"], secondiMisurati=measured,
                       secondiNelloStorico=seconds, copieNelloStorico=1, puntiGPX=len(workout["points"]))
        (loop.output / "risultato.json").write_text(json.dumps(summary, indent=2) + "\n")
        log(json.dumps(summary, ensure_ascii=False))
    except Exception:
        try:
            loop.discard_interrupted()
        except Exception as cleanup_error:
            log(f"Pulizia della sessione di prova: {cleanup_error}")
        raise
    finally:
        boot(loop.phone)
        for device in (loop.phone, loop.watch):
            subprocess.run(["xcrun", "simctl", "location", device, "clear"], check=False)


if __name__ == "__main__":
    loop = Loop(Path(sys.argv[1]))
    lock = Path(tempfile.gettempdir()) / f"runloop-5km-{loop.phone}-{loop.watch}.lock"
    with lock.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        run(loop)
