import { main } from './main';

// The bundle's entry (dist/ops/delete-global-names/bin.js): see service/docs/runbook.md, "Deleting the global names". Nothing else is here.
main(process.argv.slice(2)).then((code) => process.exit(code));
