import http from 'k6/http';
import { check } from 'k6';

const config = JSON.parse(open(__ENV.WTT_SHUTDOWN_CONFIG));

export const options = {
  scenarios: {
    shutdown: {
      executor: 'constant-arrival-rate',
      rate: config.rate,
      timeUnit: '1s',
      duration: `${config.duration}s`,
      preAllocatedVUs: config.preAllocatedVUs,
      maxVUs: config.maxVUs,
      gracefulStop: '30s',
    },
  },
  hosts: { [config.hostname]: config.peerIp },
  noConnectionReuse: true,
  noVUConnectionReuse: true,
  discardResponseBodies: true,
  insecureSkipTLSVerify: false,
  tlsVersion: { min: 'tls1.2', max: 'tls1.2' },
  tlsCipherSuites: ['TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256'],
  tags: { diagnostic: 'tls-shutdown', label: config.label },
  thresholds: {
    http_reqs: ['count>0'],
    http_req_failed: ['rate==0'],
    checks: ['rate==1'],
  },
};

export default function () {
  const response = http.get(
    `https://${config.hostname}:${config.port}/payload?bytes=1024`,
    { timeout: '10s', redirects: 0 },
  );
  check(response, {
    'HTTP 200': (r) => r.status === 200,
    'HTTP/2 negotiated': (r) => r.proto === 'HTTP/2.0',
    'TLS 1.2 negotiated': (r) => r.tls_version === 'tls1.2',
  });
}
