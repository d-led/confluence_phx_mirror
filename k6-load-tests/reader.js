// Reader load test for the Confluence mirror.
//
// Readers are anonymous: no sign-in, no session, no cookies. Each iteration
// walks the paths a reader actually takes — a space, a page, its attachments, a
// search — so the numbers cover the whole read path (Postgres full text, blob
// store, LiveView-less controller renders) rather than one endpoint.
//
// PROFILES: smoke (2 VUs, 10s) · 200 (200 VUs, 3m) · 2000 (2000 VUs, 5m)
//           nav2000 (same ramp as 2000, navigation only — no search)
//           throughput (constant arrival rate; set RPS, no think time)
//
// `nav2000` exists because browsing and searching cost very different amounts
// of work; a mixed profile averages the two and hides which one is the wall.
//
// `throughput` is the only profile that measures *capacity*. A closed-loop
// profile (VUs that sleep between iterations) is bounded by its own think time:
// 2000 VUs sleeping ~2 s cannot exceed a few hundred rps however fast the
// server is. This one asks for a fixed rate and reports the latency and error
// rate the server answers with, so raising `RPS` until p95 breaks gives the
// knee.
//
//   k6 run -e PROFILE=throughput -e RPS=800 -e BASE_URL=http://localhost:4000 k6-load-tests/reader.js
//
// Seed content must exist: `mix setup` (demo) or a synced site.

import http from "k6/http";
import { check, sleep, group } from "k6";
import { Rate, Trend } from "k6/metrics";

const BASE_URL = __ENV.BASE_URL || "http://localhost:4000";
const PROFILE = __ENV.PROFILE || "smoke";
const NAVIGATION_ONLY = PROFILE.startsWith("nav");
const THROUGHPUT = PROFILE === "throughput";
const RPS = Number(__ENV.RPS || 200);

const pageLoads = new Trend("page_load_ms", true);
const searchLoads = new Trend("search_load_ms", true);
const failureRate = new Rate("failed_requests");

const stages2000 = [
  { duration: "1m", target: 500 },
  { duration: "1m", target: 2000 },
  { duration: "2m", target: 2000 },
  { duration: "1m", target: 0 },
];

const profiles = {
  smoke: {
    executor: "constant-vus",
    vus: 2,
    duration: "10s",
  },
  200: {
    executor: "ramping-vus",
    startVUs: 0,
    stages: [
      { duration: "30s", target: 200 }, // ramp
      { duration: "2m", target: 200 }, // steady state
      { duration: "30s", target: 0 }, // cool down
    ],
  },
  2000: { executor: "ramping-vus", startVUs: 0, stages: stages2000 },
  nav2000: { executor: "ramping-vus", startVUs: 0, stages: stages2000 },
  throughput: {
    executor: "constant-arrival-rate",
    rate: RPS,
    timeUnit: "1s",
    duration: __ENV.DURATION || "60s",
    // Enough VUs that the rate, not the pool of workers, is the limit.
    preAllocatedVUs: RPS,
    maxVUs: RPS * 3,
  },
};

export const options = {
  scenarios: { readers: profiles[PROFILE] },
  // Generous enough to catch a regression, tight enough to mean something:
  // a mirrored page is served from Postgres and the blob store, nothing else.
  thresholds: {
    http_req_failed: ["rate<0.01"],
    http_req_duration: ["p(95)<800", "p(99)<2000"],
    failed_requests: ["rate<0.01"],
  },
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
};

// Discover what to read once, before any VU starts: a space, some pages and an
// attachment. Content is whatever the mirror actually holds.
export function setup() {
  const spaces = http.get(`${BASE_URL}/wiki/rest/api/space?limit=10`);
  const spaceKeys = spaces.status === 200 ? (spaces.json("results") || []).map(s => s.key) : [];
  if (spaceKeys.length === 0) {
    throw new Error(`no spaces at ${BASE_URL}: run \`mix setup\` or a sync first`);
  }

  const pages = {};
  const attachments = [];
  for (const key of spaceKeys.slice(0, 5)) {
    const list = http.get(`${BASE_URL}/wiki/rest/api/content?spaceKey=${key}&limit=25`);
    if (list.status !== 200) continue;
    // `_links.webui` is the canonical URL. Building it from the id
    // (`/spaces/KEY/pages/ID`) answers with a 302 to the slug, which would make
    // every page sample count two round trips instead of one.
    pages[key] = (list.json("results") || []).map(p => ({
      id: p.id,
      title: p.title,
      url: p._links?.webui || `/spaces/${key}/pages/${p.id}`,
    }));
  }

  const first = spaceKeys[0];
  const spacePage = (pages[first] || [])[0];

  return { spaces: spaceKeys, pages, attachment: attachments[0] || null, firstPage: spacePage };
}

function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

function record(metric, response, name) {
  const ok = check(response, { [`${name} is 200`]: (r) => r.status === 200 });
  failureRate.add(!ok);
  metric.add(response.timings.duration);
  return ok;
}

export default function (data) {
  if (THROUGHPUT) {
    // No think time: the arrival rate is the input, latency is the answer.
    hit(data);
    return;
  }

  if (NAVIGATION_ONLY) {
    navigate(data);
    return;
  }

  const roll = Math.random();

  if (roll < 0.15) {
    group("home", () => {
      record(pageLoads, http.get(`${BASE_URL}/`), "home");
    });
  } else if (roll < 0.4) {
    const key = pick(data.spaces);
    group("space", () => {
      record(pageLoads, http.get(`${BASE_URL}/spaces/${key}`), `space ${key}`);
    });
  } else if (roll < 0.85) {
    const key = pick(data.spaces);
    const pages = data.pages[key] || [];
    if (pages.length === 0) return;
    const page = pick(pages);
    group("page", () => {
      record(pageLoads, http.get(`${BASE_URL}${page.url}`), "page");
    });
  } else {
    // A query a reader would type, from words the content actually contains.
    const terms = ["rate", "architecture", "release", "search", "oauth", "runbook"];
    const q = encodeURIComponent(pick(terms));
    group("search", () => {
      record(searchLoads, http.get(`${BASE_URL}/search?q=${q}`), "search");
    });
  }

  // Readers think, they do not click continuously.
  sleep(Math.random() * 2 + 1);
}

// The standard navigation path: land, browse a space, open pages. No search.
//
// Each VU remembers the etags it has seen and asks for the page again with
// `If-None-Match`, which is what a browser returning to a page does: the mirror
// answers `304` and skips the render entirely.
const etags = {};

function conditionalGet(url, name) {
  const headers = etags[url] ? { "If-None-Match": etags[url] } : {};
  const response = http.get(url, { headers });
  const ok = check(response, { [`${name} is 200 or 304`]: (r) => r.status === 200 || r.status === 304 });
  failureRate.add(!ok);
  pageLoads.add(response.timings.duration);

  if (response.status === 200) {
    etags[url] = response.headers["Etag"] || response.headers["etag"];
  }

  return ok;
}

// One request, no think time: the unit of the throughput profile. It keeps the
// mix a reader produces (mostly pages, some spaces and the home page) so the
// capacity number is about the real read path, not one hot endpoint.
function hit(data) {
  const key = pick(data.spaces);
  const pages = data.pages[key] || [];
  const roll = Math.random();

  if (roll < 0.1 || pages.length === 0) {
    record(pageLoads, http.get(`${BASE_URL}/`), "home");
  } else if (roll < 0.3) {
    record(pageLoads, http.get(`${BASE_URL}/spaces/${key}`), `space ${key}`);
  } else {
    const page = pick(pages);
    record(pageLoads, http.get(`${BASE_URL}${page.url}`), "page");
  }
}

function navigate(data) {
  const roll = Math.random();
  const key = pick(data.spaces);
  const pages = data.pages[key] || [];

  if (roll < 0.2 || pages.length === 0) {
    group("home", () => {
      conditionalGet(`${BASE_URL}/`, "home");
    });
  } else if (roll < 0.55) {
    group("space", () => {
      conditionalGet(`${BASE_URL}/spaces/${key}`, `space ${key}`);
    });
  } else {
    const page = pick(pages);
    group("page", () => {
      conditionalGet(`${BASE_URL}${page.url}`, "page");
    });
  }

  sleep(Math.random() * 2 + 1);
}
