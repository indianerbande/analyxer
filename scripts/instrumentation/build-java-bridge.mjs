#!/usr/bin/env node
// Uses explicitly selected local dependencies; does not install or configure tools.
// npm install --prefix .local/tools/frida-probe --ignore-scripts --no-audit --no-fund frida-java-bridge@7.0.13
// node scripts/instrumentation/build-java-bridge.mjs ABS_FRIDA_MODULE_JS ABS_PROBE_DIRECTORY
import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [moduleFile, projectRoot] = process.argv.slice(2);
if (!moduleFile || !projectRoot || !path.isAbsolute(moduleFile) || !path.isAbsolute(projectRoot)) {
  throw new Error('Usage: build-java-bridge.mjs ABS_FRIDA_MODULE_JS ABS_PROBE_DIRECTORY');
}
const { default: frida } = await import(pathToFileURL(moduleFile).href);
const entry = path.join(projectRoot, 'java-bridge.js');
await fs.writeFile(entry, "import Java from 'frida-java-bridge';\nglobalThis.Java = Java;\n");
const compiler = new frida.Compiler();
const source = await compiler.build('java-bridge.js', {
  projectRoot, bundleFormat: 'iife', typeCheck: 'none', sourceMaps: frida.SourceMaps.Omitted
});
const output = path.join(projectRoot, 'java-bridge.bundle.js');
await fs.writeFile(output, source);
console.log(output);
