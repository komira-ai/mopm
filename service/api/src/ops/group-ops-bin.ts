import { main } from './group-ops-main';

// The bundle's entry (dist/ops/group-ops-bin.js): `node group-ops-bin.js --stage=<stage> --mode=status`. Nothing else is here.
main(process.argv.slice(2)).then((code) => process.exit(code));
