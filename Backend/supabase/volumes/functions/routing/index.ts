const backendURL = Deno.env.get('SUPABASE_URL');
const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
const routingURL = Deno.env.get('RUNLOOP_GRAPHHOPPER_URL');
const maxRequestBytes = 8192;
const maxRouteBytes = 2 * 1024 * 1024;
const maxWaypoints = 25;
const maxRoutePoints = 25000;
const maxLoopSeeds = 6;
const concurrentSearches = 3;

type Coordinate = { latitude: number; longitude: number };
type Mode = 'manual' | 'round_trip' | 'waypoint_loop';
type RouteResult = {
  provider: 'graphhopper';
  distanceMeters: number;
  geometry: { type: 'LineString'; coordinates: number[][] };
};

class RequestError extends Error {
  constructor(readonly status: number, readonly code: string, readonly headers?: HeadersInit) {
    super(code);
  }
}

function record(value: unknown): Record<string, unknown> | undefined {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function inRange(value: unknown, min: number, max: number): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= min && value <= max;
}

function coordinate(value: unknown): Coordinate {
  const point = record(value);
  if (!inRange(point?.latitude, -90, 90) || !inRange(point?.longitude, -180, 180)) {
    throw new RequestError(400, 'invalid_coordinate');
  }
  return { latitude: point.latitude, longitude: point.longitude };
}

async function readJSON(message: Request | Response, limit: number, sizeError: RequestError): Promise<unknown> {
  if (Number(message.headers.get('content-length')) > limit) {
    throw sizeError;
  }
  if (!message.body) throw new SyntaxError('Missing JSON body');
  const reader = message.body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let count = 0;
  let text = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.byteLength;
      if (count > limit) {
        void reader.cancel().catch(() => {});
        throw sizeError;
      }
      text += decoder.decode(value, { stream: true });
    }
    return JSON.parse(text + decoder.decode());
  } finally {
    reader.releaseLock();
  }
}

function loopSeeds(input: Record<string, unknown>, errorCode: string): number[] {
  const validSeed = (seed: unknown): seed is number => inRange(seed, 0, 2147483647) && Number.isInteger(seed);
  if (input.seeds === undefined && validSeed(input.seed)) return [input.seed];
  if (input.seed === undefined && Array.isArray(input.seeds) && input.seeds.length >= 2 &&
    input.seeds.length <= maxLoopSeeds && input.seeds.every(validSeed) && new Set(input.seeds).size === input.seeds.length) {
    return input.seeds;
  }
  throw new RequestError(400, errorCode);
}

function routingParameters(value: unknown): { searches: URLSearchParams[][]; mode: Mode } {
  const input = record(value);
  const params = new URLSearchParams({ profile: 'foot', points_encoded: 'false', instructions: 'false' });
  const append = (query: URLSearchParams, point: Coordinate) => query.append('point', `${point.latitude},${point.longitude}`);

  if (input?.mode === 'manual') {
    if (!Array.isArray(input.waypoints) || input.waypoints.length < 2 || input.waypoints.length > maxWaypoints) {
      throw new RequestError(400, 'invalid_waypoints');
    }
    for (const point of input.waypoints.map(coordinate)) append(params, point);
    return { searches: [[params]], mode: input.mode };
  }
  if (input?.mode === 'round_trip') {
    const { targetDistanceMeters } = input;
    if (!inRange(targetDistanceMeters, 500, 50000) || !Number.isInteger(targetDistanceMeters)) {
      throw new RequestError(400, 'invalid_round_trip');
    }
    const seeds = loopSeeds(input, 'invalid_round_trip');
    const headings = input.headings;
    if (headings !== undefined && (!Array.isArray(headings) || headings.length !== seeds.length ||
      !headings.every((heading) => inRange(heading, 0, 359) && Number.isInteger(heading)))) {
      throw new RequestError(400, 'invalid_round_trip');
    }
    append(params, coordinate(input.start));
    params.set('algorithm', 'round_trip');
    params.set('round_trip.distance', String(targetDistanceMeters));
    const searches = seeds.map((seed, index) => {
      const candidate = new URLSearchParams(params);
      candidate.set('round_trip.seed', String(seed));
      if (Array.isArray(headings)) candidate.set('heading', String(headings[index]));
      return [candidate];
    });
    return { searches, mode: input.mode };
  }
  if (input?.mode === 'waypoint_loop') {
    if (!Array.isArray(input.waypoints) || input.waypoints.length < 2 || input.waypoints.length > maxWaypoints) {
      throw new RequestError(400, 'invalid_waypoint_loop');
    }
    const seeds = loopSeeds(input, 'invalid_waypoint_loop');
    const anchors = input.waypoints.map(coordinate);
    const start = anchors[0];
    params.set('way_point_max_distance', '0');
    const searches = seeds.map((seed) => [0, 1, 2].map((attempt) => {
      const candidate = new URLSearchParams(params);
      const returnVia = loopWaypoint(start, anchors[anchors.length - 1], seed, attempt);
      for (const point of [...anchors, returnVia, start]) append(candidate, point);
      return candidate;
    }));
    return { searches, mode: input.mode };
  }
  throw new RequestError(400, 'invalid_mode');
}

function loopWaypoint(start: Coordinate, end: Coordinate, seed: number, attempt: number): Coordinate {
  const rad = Math.PI / 180;
  const latitude = start.latitude * rad;
  const lastLatitude = end.latitude * rad;
  const deltaLongitude = (end.longitude - start.longitude) * rad;
  const bearing = Math.atan2(Math.sin(deltaLongitude) * Math.cos(lastLatitude),
    Math.cos(latitude) * Math.sin(lastLatitude) - Math.sin(latitude) * Math.cos(lastLatitude) * Math.cos(deltaLongitude));
  const radius = 6371000;
  const chord = Math.sin((lastLatitude - latitude) / 2) ** 2 +
    Math.cos(latitude) * Math.cos(lastLatitude) * Math.sin(deltaLongitude / 2) ** 2;
  const distance = 2 * radius * Math.asin(Math.sqrt(Math.min(1, Math.max(0, chord))));
  if (distance < 15) throw new RequestError(422, 'loop_unavailable');

  const variant = seed + attempt * 1235;
  const mixed = Math.imul(variant ^ 0x9e3779b9, 0x85ebca6b) >>> 0;
  const fraction = 0.12 + (mixed & 255) / 255 * 0.76;
  const width = 0.55 + ((mixed >>> 8) & 255) / 255 * 0.9;
  const side = variant % 2 === 0 ? 1 : -1;

  function project(from: Coordinate, direction: number, meters: number): Coordinate {
    const arc = meters / radius;
    const lat = from.latitude * rad;
    const projected = Math.asin(Math.sin(lat) * Math.cos(arc) + Math.cos(lat) * Math.sin(arc) * Math.cos(direction));
    const lon = from.longitude + Math.atan2(Math.sin(direction) * Math.sin(arc) * Math.cos(lat),
      Math.cos(arc) - Math.sin(lat) * Math.sin(projected)) / rad;
    return { latitude: projected / rad, longitude: ((lon + 540) % 360) - 180 };
  }

  return project(project(start, bearing, distance * fraction), bearing + side * Math.PI / 2,
    Math.min(2000, Math.max(160 + attempt * 50, distance * width)));
}

function mostlyRetraced(coordinates: number[][]): boolean {
  const edges = new Set<string>();
  let total = 0;
  let repeated = 0;
  for (let index = 1; index < coordinates.length; index++) {
    const a = coordinates[index - 1];
    const b = coordinates[index];
    const east = (((b[0] - a[0] + 540) % 360) - 180) * Math.cos((a[1] + b[1]) * Math.PI / 360);
    const length = Math.hypot(east, b[1] - a[1]);
    const pair = [a.join(','), b.join(',')].sort().join(':');
    total += length;
    if (edges.has(pair)) repeated += length;
    edges.add(pair);
  }
  return total === 0 || repeated / total > 0.4;
}

async function authenticatedUser(request: Request): Promise<string> {
  const authorization = request.headers.get('authorization');
  if (!authorization || !/^Bearer\s+\S+$/i.test(authorization)) {
    throw new RequestError(401, 'sign_in_required');
  }
  const response = await fetch(`${backendURL}/auth/v1/user`, {
    headers: { authorization, apikey: anonKey! },
    redirect: 'error',
    signal: AbortSignal.timeout(5000),
  });
  if ([400, 401, 403].includes(response.status)) throw new RequestError(401, 'sign_in_required');
  if (!response.ok) throw new RequestError(503, 'authentication_unavailable');
  const user = record(await response.json());
  if (typeof user?.id !== 'string' || user.is_anonymous === true) {
    throw new RequestError(401, 'sign_in_required');
  }
  return user.id;
}

async function enforceRateLimit(userID: string): Promise<void> {
  const response = await fetch(`${backendURL}/rest/v1/rpc/runloop_consume_routing_quota`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${serviceKey}`,
      apikey: serviceKey!,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ p_user_id: userID }),
    redirect: 'error',
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new RequestError(503, 'routing_unavailable');
  const allowed = await response.json();
  if (allowed === false) throw new RequestError(429, 'routing_rate_limit', { 'retry-after': '60' });
  if (allowed !== true) throw new RequestError(503, 'routing_unavailable');
}

async function calculateRoute(params: URLSearchParams, mode: Mode, signal: AbortSignal): Promise<RouteResult> {
  const response = await fetch(`${routingURL}/route?${params}`, {
    redirect: 'error',
    signal,
  });
  if ([400, 404].includes(response.status)) {
    const unavailable = new RequestError(422, 'route_unavailable');
    if (response.status === 400) {
      let body: Record<string, unknown> | undefined;
      try {
        body = record(await readJSON(response, maxRequestBytes, unavailable));
      } catch {
        signal.throwIfAborted();
        throw unavailable;
      }
      // A proposed return point can fall outside the map even when all user points are valid.
      const proposedReturnIndex = mode === 'waypoint_loop' ? params.getAll('point').length - 2 : undefined;
      if (Array.isArray(body?.hints) && body.hints.some((hint: unknown) => {
        const detail = record(hint);
        return detail?.details === 'com.graphhopper.util.exceptions.PointOutOfBoundsException' &&
          typeof detail.point_index === 'number' && detail.point_index !== proposedReturnIndex;
      })) {
        throw new RequestError(422, 'outside_routing_coverage');
      }
    }
    throw unavailable;
  }
  if (!response.ok) throw new RequestError(502, 'routing_provider_unavailable');

  const invalidRoute = new RequestError(502, 'invalid_routing_response');
  let body: Record<string, unknown> | undefined;
  try {
    body = record(await readJSON(response, maxRouteBytes, invalidRoute));
  } catch (error) {
    if (error instanceof SyntaxError || error instanceof TypeError) throw invalidRoute;
    throw error;
  }
  const path = Array.isArray(body?.paths) ? record(body.paths[0]) : undefined;
  const geometry = record(path?.points);
  const coordinates = geometry?.coordinates;
  if (geometry?.type !== 'LineString' || !Array.isArray(coordinates) || coordinates.length < 2 ||
    coordinates.length > maxRoutePoints || !coordinates.every((point: unknown) =>
      Array.isArray(point) && point.length === 2 && inRange(point[0], -180, 180) && inRange(point[1], -90, 90)
    ) || !inRange(path?.distance, Number.MIN_VALUE, Number.MAX_VALUE)) {
    throw invalidRoute;
  }
  if (mode !== 'manual') {
    const start = coordinates[0];
    const end = coordinates[coordinates.length - 1];
    if (start[0] !== end[0] || start[1] !== end[1]) throw invalidRoute;
  }
  if (mode === 'waypoint_loop' && mostlyRetraced(coordinates)) throw new RequestError(422, 'loop_unavailable');
  return {
    provider: 'graphhopper',
    distanceMeters: path.distance,
    geometry: { type: 'LineString', coordinates },
  };
}

async function calculateSearch(candidates: URLSearchParams[], mode: Mode, signal: AbortSignal): Promise<RouteResult> {
  for (const params of candidates) {
    try {
      return await calculateRoute(params, mode, signal);
    } catch (error) {
      if (mode !== 'waypoint_loop' || !(error instanceof RequestError) || error.status !== 422 ||
        error.code === 'outside_routing_coverage') throw error;
    }
  }
  throw new RequestError(422, 'loop_unavailable');
}

async function calculateAlternatives(searches: URLSearchParams[][], mode: Mode, signal: AbortSignal): Promise<RouteResult[]> {
  const alternatives: RouteResult[] = [];
  let failure: unknown;
  for (let index = 0; index < searches.length && !signal.aborted; index += concurrentSearches) {
    const group = searches.slice(index, index + concurrentSearches);
    for (const result of await Promise.allSettled(group.map((candidates) => calculateSearch(candidates, mode, signal)))) {
      if (result.status === 'fulfilled') {
        alternatives.push(result.value);
      } else if (failure === undefined || (failure instanceof RequestError && failure.status === 422)) {
        failure = result.reason;
      }
    }
  }
  if (alternatives.length === 0) {
    signal.throwIfAborted();
    throw failure ?? new RequestError(422, 'route_unavailable');
  }
  return alternatives;
}

async function handle(request: Request): Promise<Response> {
  if (request.method !== 'POST') throw new RequestError(405, 'method_not_allowed', { allow: 'POST' });
  if (!backendURL || !anonKey || !serviceKey || !routingURL) throw new RequestError(503, 'routing_unavailable');
  const userID = await authenticatedUser(request);
  if (request.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() !== 'application/json') {
    throw new RequestError(415, 'expected_json');
  }
  let input: unknown;
  try {
    input = await readJSON(request, maxRequestBytes, new RequestError(413, 'routing_input_too_large'));
  } catch (error) {
    if (error instanceof RequestError) throw error;
    throw new RequestError(400, 'invalid_json');
  }
  const { searches, mode } = routingParameters(input);
  await enforceRateLimit(userID);
  const signal = AbortSignal.any([request.signal, AbortSignal.timeout(15000)]);
  const result = searches.length === 1
    ? await calculateSearch(searches[0], mode, signal)
    : { alternatives: await calculateAlternatives(searches, mode, signal) };
  return Response.json(result, { headers: { 'cache-control': 'no-store' } });
}

Deno.serve(async (request) => {
  const started = performance.now();
  let response: Response;
  try {
    response = await handle(request);
  } catch (error) {
    const failure = error instanceof RequestError ? error : error instanceof DOMException && error.name === 'TimeoutError'
      ? new RequestError(504, 'routing_timeout')
      : new RequestError(503, 'routing_unavailable');
    response = Response.json({ code: failure.code }, { status: failure.status, headers: failure.headers });
  }
  console.log(JSON.stringify({ event: 'runloop_routing', status: response.status, duration_ms: Math.round(performance.now() - started) }));
  return response;
});
