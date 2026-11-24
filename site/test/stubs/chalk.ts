// What e2b's CommonJS build gets for `require('chalk')` under jest (jest.config.js, moduleNameMapper). chalk 5 is an ES
// module only, which jest's CommonJS loader cannot load. e2b uses it only to colour its template builder's log (it builds
// a few coloured labels when it loads), and the tutorial never builds a template. So every colour, chained or called,
// gives back its text unchanged, and the colour makers (`hex('#FF4400')`, ...) give such a colour. The browser bundle
// (tools/build.ts) has the real chalk: esbuild reads ES modules.
type Paint = ((text: unknown) => string) & { readonly [colour: string]: Paint };

const MAKERS = new Set(['hex', 'bgHex', 'rgb', 'bgRgb', 'ansi256', 'bgAnsi256']);

const paint: Paint = new Proxy((text: unknown) => String(text), {
  get: (_target, key) => (typeof key === 'string' && MAKERS.has(key) ? () => paint : paint),
}) as Paint;

export default paint;
