module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  // The package's own code, for jest --coverage (buildrules' rules/coverage/README.md, `jest_test(coverage = True)`).
  collectCoverageFrom: ['src/**/*.ts', 'tools/**/*.ts'],
  testMatch: ['**/*.test.ts'],
  // TypeScript first: a stray compiled test/x.js must never shadow test/x.ts.
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }] },
  // Sources import each other as './x.js' (what the browser loads); under Jest those resolve to the .ts files.
  // e2b's CommonJS build requires chalk, an ES module only; test/stubs/chalk.ts says why a stand-in is enough.
  moduleNameMapper: { '^(\\.{1,2}/.*)\\.js$': '$1', '^chalk$': '<rootDir>/test/stubs/chalk.ts' },
  setupFiles: ['<rootDir>/test/setup.ts'],
};
