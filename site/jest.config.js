module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  // The package's own code, for jest --coverage (vendor/buildrules_coverage/README.md).
  collectCoverageFrom: ['src/**/*.ts', 'tools/**/*.ts'],
  testMatch: ['**/*.test.ts'],
  // TypeScript first: a stray compiled test/x.js must never shadow test/x.ts.
  moduleFileExtensions: ['ts', 'js', 'json'],
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }] },
  // Sources import each other as './x.js' (what the browser loads); under Jest those resolve to the .ts files.
  moduleNameMapper: { '^(\\.{1,2}/.*)\\.js$': '$1' },
  setupFiles: ['<rootDir>/test/setup.ts'],
};
