// The build wrote every page service-ci.yml's site job checks for (`test -f dist/<page>`).
const fs = require('node:fs');
const PAGES = ['index.html', 'app.html', '404.html', 'docs/index.html', 'docs/mopm-toml/index.html', 'docs/mopm-test/index.html'];
const missing = PAGES.filter((p) => !(fs.existsSync(`dist/${p}`) && fs.statSync(`dist/${p}`).isFile()));
if (missing.length > 0) throw new Error(`dist/ lacks ${missing.join(', ')}`);
