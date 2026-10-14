module.exports = {
  testEnvironment: 'node',
  roots: ['<rootDir>/test'],
  testMatch: ['**/*.test.ts'],
  transform: { '^.+\\.tsx?$': ['ts-jest', { tsconfig: 'tsconfig.json' }] },
  // Sources import each other as './x.js' (what the browser loads); under Jest those resolve to the .ts files.
  moduleNameMapper: { '^(\\.{1,2}/.*)\\.js$': '$1' },
  setupFiles: ['<rootDir>/test/setup.ts'],
};
