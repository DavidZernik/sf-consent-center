/**
 * Points the HTML at the content-hashed assets rollup emitted, and hashes the stylesheet.
 *
 * Why any of this exists: GitHub Pages serves every file with `Cache-Control: max-age=600`
 * and gives no way to change that. With a stable `app.js` URL a browser that has the file
 * cached keeps running the old application, and the only fix available to a visitor is a hard
 * refresh, not something you can ask a recruiter to do. Hashing makes each new build a URL
 * nothing has cached, so an update cannot be missed.
 *
 * The JS hashing itself is done by rollup, not here. Every code-split chunk imports shared
 * bindings back from the entry (`import {...} from "../app.js"`), so renaming the entry after
 * the fact breaks all of them: the chunk still returns 200, its own back-import 404s, and the
 * browser reports "Failed to fetch dynamically imported module" against the chunk URL. Only
 * rollup rewrites those back-references. This script therefore discovers the name rollup chose
 * rather than assigning one.
 *
 * index.css has no such back-references (nothing imports it) so it is safe to hash here.
 *
 * index.html stays at a stable URL and is still cached for ten minutes. That window is
 * unavoidable on Pages, but it is self-healing: the stale HTML names a bundle that still
 * exists, and the next load past the ten minutes picks up the new one.
 */
import { createHash } from 'node:crypto';
import { readFile, writeFile, rename, readdir, unlink } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DIST = join(ROOT, 'dist');
const HTML_FILES = ['index.html', '404.html'];
const ENTRY_PATTERN = /^app-[A-Za-z0-9_-]+\.js$/;

const distFiles = await readdir(DIST);

// Rollup does not clean dist, so a rebuild can leave the previous bundle behind. Whichever
// name index.html ends up pointing at must be the one from this build, so identify it by
// modification time rather than assuming there is only one.
const entries = distFiles.filter((name) => ENTRY_PATTERN.test(name));
if (entries.length === 0) {
    throw new Error('No dist/app-<hash>.js found. Did rollup run?');
}
const { statSync } = await import('node:fs');
entries.sort((a, b) => statSync(join(DIST, b)).mtimeMs - statSync(join(DIST, a)).mtimeMs);
const jsName = entries[0];

// Stale bundles from earlier builds would otherwise pile up in the deployed artifact.
for (const name of distFiles) {
    if (ENTRY_PATTERN.test(name) && name !== jsName) {
        await unlink(join(DIST, name));
    }
}

/** Eight hex characters is ~4 billion values, ample for separating one build from the next. */
async function hashStylesheet() {
    const source = join(DIST, 'index.css');
    if (!existsSync(source)) {
        throw new Error('index.css is missing from dist. Did copy-assets run?');
    }
    const contents = await readFile(source);
    const hashed = `index-${createHash('sha256').update(contents).digest('hex').slice(0, 8)}.css`;

    for (const name of distFiles) {
        if (/^index-[0-9a-f]{8}\.css$/.test(name) && name !== hashed) {
            await unlink(join(DIST, name));
        }
    }
    await rename(source, join(DIST, hashed));
    return hashed;
}

const cssName = await hashStylesheet();

for (const file of HTML_FILES) {
    const path = join(DIST, file);
    const html = await readFile(path, 'utf8');
    const rewritten = html.replace('./app.js', `./${jsName}`).replace('./index.css', `./${cssName}`);

    // A silent no-op here ships an index.html naming files that do not exist, which is a blank
    // page rather than a stale one. Fail the build instead of deploying that.
    if (rewritten.includes('./app.js') || rewritten.includes('./index.css')) {
        throw new Error(`${file} still references an unhashed asset after rewriting.`);
    }
    if (!rewritten.includes(jsName) || !rewritten.includes(cssName)) {
        throw new Error(`${file} does not reference the hashed assets.`);
    }
    await writeFile(path, rewritten, 'utf8');
}

// The failure this script exists to prevent is subtle and only shows up in a browser, so
// assert the chunk back-references resolve rather than trusting that they do.
for (const name of await readdir(join(DIST, 'chunks'))) {
    const chunk = await readFile(join(DIST, 'chunks', name), 'utf8');
    for (const [, specifier] of chunk.matchAll(/from"\.\.\/([^"]+)"/g)) {
        if (!existsSync(join(DIST, specifier))) {
            throw new Error(`chunks/${name} imports ../${specifier}, which does not exist.`);
        }
    }
}

console.log(`fingerprint: ${jsName} · ${cssName}`);
