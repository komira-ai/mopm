// Cap workers: unbounded workers exhaust memory on many-core machines (ts-jest workers reach ~1.6 GB each).
module.exports = {
  maxWorkers: 2,
  workerIdleMemoryLimit: '1GB',
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  // The package's own code, for jest --coverage (vendor/buildrules_coverage/README.md).
  collectCoverageFrom: ['bin/**/*.ts', 'lib/**/*.ts'],
  testMatch: ['**/*.test.ts'],
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }] },
};
