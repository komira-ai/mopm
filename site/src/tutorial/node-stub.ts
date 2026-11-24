// The module the tutorial bundle gives e2b's six `node:*` imports (tools/build.ts, NODE_STUBS): e2b 2.64.0 imports
// node:fs, node:stream, node:crypto, node:os, node:path and node:url at the top of its ES module, and only its template
// builder, which the page never calls, uses them (docs/design/tutorial-sign-in.md, section 4.1). Empty on purpose: it
// has no import or export, so esbuild reads it as a CommonJS module with no exports, and every name imported from it is
// undefined.
