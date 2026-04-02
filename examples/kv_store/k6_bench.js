import http from "k6/http";
import exec from "k6/execution";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

const putLatency = new Trend("put_latency", true);
const getLatency = new Trend("get_latency", true);
const putErrors = new Counter("put_errors");
const getErrors = new Counter("get_errors");

const NODES = [
  "http://127.0.0.1:8001",
  "http://127.0.0.1:8002",
  "http://127.0.0.1:8003",
];

// Find leader at startup
let leaderUrl = NODES[0];

export function setup() {
  for (const node of NODES) {
    const res = http.get(`${node}/_status`, { redirects: 0 });
    if (res.status === 200) {
      try {
        const status = JSON.parse(res.body);
        if (status.role === "leader") {
          return { leader: node };
        }
      } catch (_e) {
        // ignore
      }
    }
  }
  return { leader: NODES[0] };
}

export const options = {
  scenarios: {
    write_1vu: {
      executor: "constant-vus",
      vus: 1,
      duration: "10s",
      tags: { phase: "write" },
    },
    write_2vu: {
      executor: "constant-vus",
      vus: 2,
      duration: "10s",
      startTime: "12s",
      tags: { phase: "write" },
    },
    write_5vu: {
      executor: "constant-vus",
      vus: 5,
      duration: "10s",
      startTime: "24s",
      tags: { phase: "write" },
    },
    read_10vu: {
      executor: "constant-vus",
      vus: 10,
      duration: "10s",
      startTime: "36s",
      tags: { phase: "read" },
    },
    read_100vu: {
      executor: "constant-vus",
      vus: 100,
      duration: "10s",
      startTime: "48s",
      tags: { phase: "read" },
    },
  },
};

export default function (data) {
  const base = data.leader;
  const scenario = exec.scenario.name;
  const vu = __VU;
  const iter = __ITER;
  const key = `k-${vu}-${iter}`;

  if (scenario.startsWith("write_")) {
    const res = http.put(`${base}/${key}`, `val-${iter}`, { redirects: 3 });
    putLatency.add(res.timings.duration);
    if (!check(res, { "put 201": (r) => r.status === 201 })) {
      putErrors.add(1);
    }
    return;
  }

  if (scenario.startsWith("read_")) {
    const res = http.get(`${base}/k-${vu}-0`, { redirects: 3 });
    getLatency.add(res.timings.duration);
    if (!check(res, { "get 200|404": (r) => r.status === 200 || r.status === 404 })) {
      getErrors.add(1);
    }
    return;
  }
}

export function handleSummary(data) {
  const fmt = (v) => (v !== undefined && v !== null ? v.toFixed(2) : "N/A");

  let lines = ["\n=== KV Store Benchmark Summary ==="];

  // Per-scenario breakdown from group/scenario tags
  const scenarios = [
    "write_10vu", "write_100vu", "write_1000vu",
    "read_10vu", "read_100vu", "read_1000vu",
  ];

  for (const sc of scenarios) {
    const iters = data.metrics[`iterations{scenario:${sc}}`];
    if (iters && iters.values) {
      const v = iters.values;
      lines.push(`  ${sc}: ${v.count} iters  ${fmt(v.rate)}/s`);
    }
  }

  lines.push("");

  const put = data.metrics.put_latency;
  if (put && put.values) {
    const v = put.values;
    lines.push(
      `  PUT:  avg=${fmt(v.avg)}ms  p50=${fmt(v.med)}ms  p95=${fmt(v["p(95)"])}ms  p99=${fmt(v["p(99)"])}ms`
    );
  }

  const get = data.metrics.get_latency;
  if (get && get.values) {
    const v = get.values;
    lines.push(
      `  GET:  avg=${fmt(v.avg)}ms  p50=${fmt(v.med)}ms  p95=${fmt(v["p(95)"])}ms  p99=${fmt(v["p(99)"])}ms`
    );
  }

  const reqs = data.metrics.http_reqs;
  if (reqs && reqs.values) {
    lines.push(`  Rate:  ${fmt(reqs.values.rate)} req/s  total=${reqs.values.count}`);
  }

  const pe = data.metrics.put_errors;
  const ge = data.metrics.get_errors;
  lines.push(
    `  Errors: put=${pe ? pe.values.count : 0}  get=${ge ? ge.values.count : 0}`
  );

  lines.push("==================================\n");

  console.log(lines.join("\n"));
  return {};
}
