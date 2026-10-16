// The build wrote the Lambda handler (service-ci.yml: `test -f dist/http/lambda.js`).
const fs = require('node:fs');
if (!fs.statSync('dist/http/lambda.js').isFile()) throw new Error('dist/http/lambda.js is not a file');
