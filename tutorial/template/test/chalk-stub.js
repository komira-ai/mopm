// e2b's CommonJS build requires chalk 5, which is ESM-only and cannot load in Jest's CommonJS runtime (jest.config.js
// maps it here). e2b uses it only to colour build log lines, and no test prints one. Every style is the identity: a
// call (`chalk.red(s)`, `chalk.hex(c)(s)`) gives a value that is again a style and reads as the last text it was given.
function styled(text) {
  const f = function () {};
  return new Proxy(f, {
    get: (_t, key) => (key === Symbol.toPrimitive || key === 'toString' ? () => text : styled(text)),
    apply: (_t, _this, args) => styled(String(args[0])),
  });
}
module.exports = { __esModule: true, default: styled('') };
