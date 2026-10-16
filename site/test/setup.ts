// Runs before every test file: no test may reach the network. Code under test gets fetch injected; a call to the
// global one is a bug in the test or the code, and fails loudly.
globalThis.fetch = (() => {
  throw new Error('network call in a test');
}) as typeof fetch;
