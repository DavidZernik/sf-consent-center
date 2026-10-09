/**
 * Builds the manifest that powers the View source panel.
 *
 * Reads the real Salesforce metadata out of force-app/ at build time and emits it as JSON, so
 * the panel shows the same bytes that would deploy to an org rather than a copy that can drift.
 *
 * The build FAILS if a path referenced by the capability map does not exist. That check is the
 * whole point: a portfolio that links to code which has been renamed or deleted is worse than
 * one that links to nothing.
 */
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, relative, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const OUT_DIR = join(ROOT, 'demo', 'src', 'generated');
const OUT_FILE = join(OUT_DIR, 'sources.json');

/** Directories to publish, in the order they should appear in the panel. */
const INCLUDES = [
    { dir: 'backend/src/main/java', group: 'Java backend', extensions: ['.java'] },
    { dir: 'backend/src/test/java', group: 'Java tests', extensions: ['.java'] },
    { dir: 'force-app/main/default/classes', group: 'Apex classes', extensions: ['.cls'] },
    { dir: 'force-app/main/default/triggers', group: 'Triggers', extensions: ['.trigger'] },
    { dir: 'force-app/main/default/lwc', group: 'Lightning Web Components', extensions: ['.js', '.html', '.css'] },
    { dir: 'force-app/main/default/pages', group: 'Visualforce', extensions: ['.page'] },
    { dir: 'force-app/main/default/flows', group: 'Flows', extensions: ['.xml'] },
    { dir: 'force-app/main/default/objects', group: 'Custom objects', extensions: ['.xml'] },
    { dir: 'force-app/main/default/permissionsets', group: 'Security', extensions: ['.xml'] },
    { dir: 'force-app/main/default/namedCredentials', group: 'Security', extensions: ['.xml'] },
    { dir: 'force-app/main/default/externalCredentials', group: 'Security', extensions: ['.xml'] },
    { dir: 'demo/src/mocks', group: 'Demo mocks', extensions: ['.js'] },
    { dir: '.github/workflows', group: 'CI', extensions: ['.yml'] }
];

/** Standalone files worth showing that do not live under an included directory. */
const EXTRA_FILES = ['backend/pom.xml', 'lwc.config.json', 'rollup.config.mjs', 'sfdx-project.json', 'pmd/apex-ruleset.xml'];

/** Excluded because they add bulk without telling a reviewer anything. */
const EXCLUDE_PATTERNS = [/__tests__\/.*\.test\.js$/, /\.cls-meta\.xml$/, /\.trigger-meta\.xml$/, /js-meta\.xml$/];

async function walk(dir) {
    const results = [];
    let entries;
    try {
        entries = await readdir(dir, { withFileTypes: true });
    } catch {
        return results;
    }
    for (const entry of entries) {
        const full = join(dir, entry.name);
        if (entry.isDirectory()) {
            results.push(...(await walk(full)));
        } else {
            results.push(full);
        }
    }
    return results;
}

async function main() {
    const files = {};
    let totalBytes = 0;

    for (const include of INCLUDES) {
        const absolute = join(ROOT, include.dir);
        if (!existsSync(absolute)) continue;

        for (const file of await walk(absolute)) {
            const rel = relative(ROOT, file).split('\\').join('/');
            if (!include.extensions.includes(extname(file))) continue;
            if (EXCLUDE_PATTERNS.some((pattern) => pattern.test(rel))) continue;

            const content = await readFile(file, 'utf8');
            totalBytes += content.length;
            files[rel] = { group: include.group, content };
        }
    }

    for (const rel of EXTRA_FILES) {
        const absolute = join(ROOT, rel);
        if (!existsSync(absolute)) continue;
        const content = await readFile(absolute, 'utf8');
        totalBytes += content.length;
        files[rel] = { group: 'Build', content };
    }

    // Tests are excluded from the bulk walk above but explicitly re-added, because the LWC test
    // files are some of the most worth reading.
    for (const file of await walk(join(ROOT, 'force-app/main/default/lwc'))) {
        const rel = relative(ROOT, file).split('\\').join('/');
        if (!/__tests__\/.*\.test\.js$/.test(rel)) continue;
        const content = await readFile(file, 'utf8');
        totalBytes += content.length;
        files[rel] = { group: 'Component tests', content };
    }

    // --- Integrity check against the capability map ---
    const capabilityModule = await readFile(
        join(ROOT, 'demo/src/modules/demo/capabilityMap/capabilities.js'),
        'utf8'
    );
    const referenced = [...capabilityModule.matchAll(/'(force-app\/[^']+)'/g)].map((match) => match[1]);
    const missing = referenced.filter((path) => !files[path] && !existsSync(join(ROOT, path)));

    if (missing.length > 0) {
        console.error('\nCapability map references files that do not exist:');
        for (const path of missing) console.error(`  - ${path}`);
        console.error('\nUpdate demo/src/modules/demo/capabilityMap/capabilities.js or restore the files.\n');
        process.exit(1);
    }

    // Any capability path not swept up by the include rules is added so its chip still opens.
    for (const path of referenced) {
        if (!files[path] && existsSync(join(ROOT, path))) {
            files[path] = { group: 'Referenced', content: await readFile(join(ROOT, path), 'utf8') };
        }
    }

    await mkdir(OUT_DIR, { recursive: true });
    await writeFile(OUT_FILE, JSON.stringify({ generatedAt: null, files }, null, 0), 'utf8');

    const count = Object.keys(files).length;
    console.log(
        `sources.json: ${count} files, ${(totalBytes / 1024).toFixed(0)} KB source, ` +
        `${referenced.length} capability references verified.`
    );
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
