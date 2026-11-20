module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  // The package's own code, for jest --coverage (buildrules' rules/coverage/README.md, `jest_test(coverage = True)`).
  // build.ts is not listed: it only forwards to src/cli.ts's main, which the tests run.
  collectCoverageFrom: ['src/**/*.ts'],
  testMatch: ['**/*.test.ts'],
  // TypeScript first: a stray compiled test/x.js must never shadow test/x.ts.
  moduleFileExtensions: ['ts', 'js', 'json'],
  // e2b's CommonJS build requires chalk 5, which is ESM-only and cannot load in Jest's CommonJS runtime; e2b uses it
  // only to colour build logs. test/chalk-stub.js stands in for it under Jest only.
  moduleNameMapper: { '^chalk$': '<rootDir>/test/chalk-stub.js' },
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }] },
};
