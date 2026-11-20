// The held build command of the tutorial's E2B template (README.md). Only forwards to src/cli.ts, where it is tested.
import { main, realDeps } from './src/cli';

main(process.argv.slice(2), realDeps()).then((code) => process.exit(code));
