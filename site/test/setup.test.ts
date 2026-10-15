// T1: the setup file replaces the global fetch, so a test that reaches for the network fails instead of calling out.
test('the global fetch throws in every test', () => {
  expect(() => fetch('https://mopm.dev/')).toThrow('network call in a test');
});
