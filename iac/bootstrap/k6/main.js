import http from 'k6/http';
import { check } from 'k6';

const config = JSON.parse(open('./config.json'));
const tlsGroup = config.tlsVersion === 'none' ? 'none' : (config.tlsGroup ?? 'P-256');
if (config.tlsVersion !== 'none' &&
    (!['P-256', 'X25519'].includes(tlsGroup) ||
     config.tlsGroupEvidence?.source !== 'openssl-preflight' ||
     config.tlsGroupEvidence?.scope !== 'client-facing-preflight' ||
     config.tlsGroupEvidence?.group !== tlsGroup ||
     config.tlsGroupEvidence?.tls_version !== config.tlsVersion)) {
  throw new Error('TLS requires matching live group evidence from bench-runner.sh');
}
const requestUrl = config.payloadBytes
  ? `${config.targetUrl}${config.endpoint}?bytes=${config.payloadBytes}`
  : `${config.targetUrl}${config.endpoint}`;

function sineStages(amplitude, offset, cycles, durationSeconds, sampling) {
  const stageSeconds = Math.max(1, Math.round(durationSeconds / sampling));

  return Array.from({ length: sampling }, (_, index) => {
    const position = (index + 1) / sampling;
    return {
      duration: `${stageSeconds}s`,
      target: Math.max(1, Math.round(offset + amplitude * Math.sin((2 * Math.PI * cycles * position) - (Math.PI / 2)))),
    };
  });
}

function linearStages(start, end, durationSeconds, sampling) {
  const stageSeconds = Math.max(1, Math.round(durationSeconds / sampling));

  return Array.from({ length: sampling }, (_, index) => ({
    duration: `${stageSeconds}s`,
    target: Math.max(1, Math.round(start + ((end - start) * (index + 1) / sampling))),
  }));
}

function exponentialStages(start, end, durationSeconds, sampling) {
  const stageSeconds = Math.max(1, Math.round(durationSeconds / sampling));
  const growthFactor = (end / start) ** (1 / sampling);

  return Array.from({ length: sampling }, (_, index) => ({
    duration: `${stageSeconds}s`,
    target: Math.round(start * growthFactor ** (index + 1)),
  }));
}

const executor = config.profile === 'race'
  ? {
      race: {
        executor: 'shared-iterations',
        vus: config.raceVUs,
        iterations: config.raceIterations,
        maxDuration: `${config.durationSeconds}s`,
        gracefulStop: '0s',
      },
    }
  : config.profile === 'sine'
  ? {
      sine: {
        executor: 'ramping-arrival-rate',
        startRate: Math.max(1, config.offset - config.amplitude),
        timeUnit: '1s',
        preAllocatedVUs: config.preAllocatedVUs,
        maxVUs: config.maxVUs ?? config.preAllocatedVUs,
        stages: sineStages(config.amplitude, config.offset, config.cycles, config.durationSeconds, config.sampling),
      },
    }
  : config.profile === 'linear'
    ? {
        linear: {
          executor: 'ramping-arrival-rate',
          startRate: config.start,
          timeUnit: '1s',
          preAllocatedVUs: config.preAllocatedVUs,
          maxVUs: config.maxVUs ?? config.preAllocatedVUs,
          stages: linearStages(config.start, config.end, config.durationSeconds, config.sampling),
        },
      }
    : config.profile === 'exponential'
      ? {
          exponential: {
            executor: 'ramping-arrival-rate',
            startRate: config.start,
            timeUnit: '1s',
            preAllocatedVUs: config.preAllocatedVUs,
            maxVUs: config.maxVUs ?? config.preAllocatedVUs,
            stages: exponentialStages(config.start, config.end, config.durationSeconds, config.sampling),
          },
        }
  : {
      flat: {
        executor: 'constant-arrival-rate',
        rate: config.rate,
        timeUnit: '1s',
        duration: `${config.durationSeconds}s`,
        preAllocatedVUs: config.preAllocatedVUs,
        maxVUs: config.maxVUs ?? config.preAllocatedVUs,
      },
    };

export const options = {
  scenarios: executor,
  discardResponseBodies: true,
  noConnectionReuse: !config.connectionReuse,
  noVUConnectionReuse: !config.connectionReuse,
  tags: {
    wtt_run_id: config.runId,
    ...(config.runName !== undefined ? { wtt_run_name: config.runName } : {}),
    ...(config.executionIndex !== undefined ? { wtt_execution_index: String(config.executionIndex) } : {}),
    wtt_scenario: config.scenario,
    wtt_stack: config.stack,
    wtt_tls_termination: config.tlsTerminatedAt,
    wtt_profile: config.profile,
    wtt_offered_rps: config.profile === 'race'
      ? 'none'
      : String(config.profile === 'flat' ? config.rate : config.peakRate),
    wtt_connection_reuse: String(config.connectionReuse),
    wtt_client_source_ip_count: String(config.clientSourceIPs.length),
    tls_resumption: String(config.tlsVersion === 'none' ? false : config.tlsResumption),
    wtt_tls_group_configured: tlsGroup,
    wtt_tls_group_verified: tlsGroup,
    wtt_tls_group_evidence: config.tlsVersion === 'none' ? 'not-applicable' : 'openssl-preflight',
  },
  tlsVersion: config.tlsVersion === 'none' ? undefined : { min: `tls${config.tlsVersion}`, max: `tls${config.tlsVersion}` },
  // The OpenSSL preflight verifies the protocol before each cell. A transport
  // failure has no k6 TLS version, so this must not reject saturation results.
  thresholds: {},
  tlsCipherSuites: config.tlsVersion === '1.2'
    ? ['TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256']
    : undefined,
};

export default function () {
  const response = http.get(requestUrl, { timeout: '10s' });
  const checks = { 'status is 200': (result) => result.status === 200 };
  if (config.tlsVersion !== 'none' && response.tls_version &&
      response.tls_version !== `tls${config.tlsVersion}`) {
    console.warn(
      `TLS version mismatch: expected tls${config.tlsVersion}, got ${response.tls_version}`,
    );
  }
  if (config.profile === 'race' && config.httpVersion === '2') {
    checks['HTTP/2 negotiated'] = (result) => result.proto === 'HTTP/2.0';
  }
  check(response, checks);
}

function round(value, decimals = 6) {
  if (value === undefined || value === null || Number.isNaN(value)) {
    return 0;
  }

  const factor = 10 ** decimals;
  return Math.round(value * factor) / factor;
}

function trendSummary(metric) {
  if (!metric) {
    return null;
  }

  const values = metric.values;
  return {
    avg: round(values.avg, 6),
    min: round(values.min, 6),
    p50: round(values['p(50)'] ?? values.med, 6),
    p90: round(values['p(90)'], 6),
    p95: round(values['p(95)'], 6),
    p99: round(values['p(99)'], 6),
    max: round(values.max, 6),
  };
}

function counterValue(metric) {
  return metric?.values?.count ?? 0;
}

function rateSummary(metric) {
  if (!metric) {
    return null;
  }

  return {
    rate: metric.values.rate ?? 0,
    passes: metric.values.passes ?? 0,
    fails: metric.values.fails ?? 0,
  };
}

export function handleSummary(data) {
  const duration = data.metrics.http_req_duration?.values ?? {};
  const handshaking = data.metrics.http_req_tls_handshaking?.values ?? null;
  const connecting = data.metrics.http_req_connecting?.values ?? null;
  const requests = data.metrics.http_reqs?.values ?? {};
  const failures = data.metrics.http_req_failed?.values ?? {};
  const failureSummary = rateSummary(data.metrics.http_req_failed);
  const droppedIterations = counterValue(data.metrics.dropped_iterations);
  const failedRequests = failureSummary?.passes ?? 0;
  const raceIterations = counterValue(data.metrics.iterations);
  const raceComplete = config.profile === 'race' && raceIterations === config.raceIterations;
  const raceElapsedMs = config.profile === 'race'
    ? round(data.state?.testRunDurationMs, 3)
    : null;

  const record = {
    run_id: config.runId,
    run_name: config.runName,
    execution_index: config.executionIndex,
    scenario: config.scenario,
    stack: config.stack,
    tls_terminated_at: config.tlsTerminatedAt,
    http_version: String(config.httpVersion),
    tls_version: config.tlsVersion,
    cipher_suite: config.tlsVersion === 'none'
      ? 'none'
      : config.tlsVersion === '1.2'
        ? 'TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256'
        : 'TLS_AES_128_GCM_SHA256',
    key_exchange_group: tlsGroup,
    key_exchange_group_configured: tlsGroup,
    key_exchange_group_source: config.tlsVersion === 'none' ? 'not-applicable' : 'openssl-preflight',
    key_exchange_group_per_request: config.tlsVersion === 'none' ? 'none' : 'unexposed-by-runtime',
    tls_group_evidence: config.tlsGroupEvidence ?? null,
    endpoint: config.endpoint,
    payload_bytes: config.payloadBytes,
    tls_resumption: config.tlsVersion === 'none' ? false : config.tlsResumption,
    connection_reuse: config.connectionReuse,
    client_source_ips: config.clientSourceIPs,
    load_tool: 'k6',
    vus: config.preAllocatedVUs,
    max_vus: config.maxVUs ?? config.preAllocatedVUs,
    duration_s: config.durationSeconds,
    iterations: requests.count ?? 0,
    rps: round(requests.rate, 6),
    latency_ms: {
      avg: round(duration.avg),
      p50: round(duration['p(50)'] ?? duration.med),
      p90: round(duration['p(90)']),
      p95: round(duration['p(95)']),
      p99: round(duration['p(99)']),
      max: round(duration.max),
    },
    tls_handshake_ms: handshaking
      ? { avg: round(handshaking.avg), p95: round(handshaking['p(95)']) }
      : null,
    http_req_connecting_ms: connecting
      ? { avg: round(connecting.avg), p95: round(connecting['p(95)']) }
      : null,
    errors: { total: failures.passes ?? 0, non_2xx: failures.passes ?? 0, timeouts: 0, tls: 0 },
    warmup: config.warmup,
    profile: config.profile,
    rate: config.profile === 'flat' ? config.rate : null,
    peak_rate: config.profile === 'flat' ? null : config.peakRate,
    image_reference: config.imageReference,
    image_digest: config.imageDigest,
    server_metadata: config.serverMetadata,
    path: 'private',
    web_dashboard: config.dashboardEnabled,
    capacity_valid: droppedIterations === 0 && failedRequests === 0,
    capacity_invalid_reason: droppedIterations > 0
      ? 'dropped_iterations'
      : failedRequests > 0
        ? 'failed_requests'
        : null,
    race: config.profile === 'race'
      ? {
          configured_iterations: config.raceIterations,
          vus: config.raceVUs,
          max_duration_s: config.durationSeconds,
          elapsed_ms: raceElapsedMs,
          completed_iterations: raceIterations,
          successful_requests: (requests.count ?? 0) - failedRequests,
          failed_requests: failedRequests,
          complete: raceComplete,
          eligible_for_finish_time_ranking: raceComplete,
        }
      : null,
    k6: {
      counters: {
        data_received_bytes: counterValue(data.metrics.data_received),
        data_sent_bytes: counterValue(data.metrics.data_sent),
        dropped_iterations: droppedIterations,
        http_reqs: counterValue(data.metrics.http_reqs),
        iterations: counterValue(data.metrics.iterations),
      },
      rates: {
        checks: rateSummary(data.metrics.checks),
        http_req_failed: failureSummary,
      },
      gauges: {
        vus: data.metrics.vus?.values ?? null,
        vus_max: data.metrics.vus_max?.values ?? null,
      },
      trends_ms: {
        iteration_duration: trendSummary(data.metrics.iteration_duration),
        http_req_blocked: trendSummary(data.metrics.http_req_blocked),
        http_req_connecting: trendSummary(data.metrics.http_req_connecting),
        http_req_duration: trendSummary(data.metrics.http_req_duration),
        http_req_receiving: trendSummary(data.metrics.http_req_receiving),
        http_req_sending: trendSummary(data.metrics.http_req_sending),
        http_req_tls_handshaking: trendSummary(data.metrics.http_req_tls_handshaking),
        http_req_waiting: trendSummary(data.metrics.http_req_waiting),
      },
    },
  };

  return { [config.recordPath]: `${JSON.stringify(record)}\n` };
}
