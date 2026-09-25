import { options as shutdownOptions } from './client-tls-shutdown.js';

export { default } from './client-tls-shutdown.js';

export const options = {
  ...shutdownOptions,
  scenarios: {
    shutdown: {
      ...shutdownOptions.scenarios.shutdown,
      rate: 2000,
      duration: '60s',
      preAllocatedVUs: 200,
      maxVUs: 1000,
    },
  },
  tags: { ...shutdownOptions.tags, diagnostic: 'tls-exhaustion' },
};
