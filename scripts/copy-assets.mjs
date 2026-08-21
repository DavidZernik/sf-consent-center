/**
 * Stages the static assets the built site needs.
 *
 * The SLDS package ships about 30 MB, every icon as an individual SVG, several stylesheet
 * variants, plus fonts. A GitHub Pages deploy that size is slow to publish and slower to load,
 * so only the minified stylesheet and the sprite sheets actually referenced are copied.
 */
import { cp, mkdir, rm, writeFile, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const SLDS = join(ROOT, 'node_modules', '@salesforce-ux', 'design-system', 'assets');
const DIST = join(ROOT, 'dist');

/** Sprite sheets only. The individual per-icon SVGs are what make the package enormous. */
const ICON_SPRITES = ['action', 'custom', 'doctype', 'standard', 'utility'];

async function directorySize(dir) {
    const { readdir } = await import('node:fs/promises');
    let total = 0;
    for (const entry of await readdir(dir, { withFileTypes: true })) {
        const full = join(dir, entry.name);
        total += entry.isDirectory() ? await directorySize(full) : (await stat(full)).size;
    }
    return total;
}

async function main() {
    await rm(DIST, { recursive: true, force: true });
    await mkdir(join(DIST, 'assets', 'styles'), { recursive: true });
    await mkdir(join(DIST, 'assets', 'icons'), { recursive: true });

    await cp(
        join(SLDS, 'styles', 'salesforce-lightning-design-system.min.css'),
        join(DIST, 'assets', 'styles', 'salesforce-lightning-design-system.min.css')
    );

    for (const sprite of ICON_SPRITES) {
        const source = join(SLDS, 'icons', `${sprite}-sprite`, 'svg', 'symbols.svg');
        if (existsSync(source)) {
            await mkdir(join(DIST, 'assets', 'icons', `${sprite}-sprite`, 'svg'), { recursive: true });
            await cp(source, join(DIST, 'assets', 'icons', `${sprite}-sprite`, 'svg', 'symbols.svg'));
        }
    }

    // Fonts are referenced by the stylesheet with a relative ../fonts path.
    if (existsSync(join(SLDS, 'fonts'))) {
        await cp(join(SLDS, 'fonts'), join(DIST, 'assets', 'fonts'), { recursive: true });
    }

    await cp(join(ROOT, 'demo', 'src', 'index.html'), join(DIST, 'index.html'));
    await cp(join(ROOT, 'demo', 'src', 'index.css'), join(DIST, 'index.css'));

    // GitHub Pages serves 404.html for unknown paths. Pointing it at the app means a stale or
    // hand-edited deep link lands on the demo instead of a GitHub error page.
    await cp(join(ROOT, 'demo', 'src', 'index.html'), join(DIST, '404.html'));

    // Tells GitHub Pages not to run the output through Jekyll, which would strip files
    // beginning with an underscore.
    await writeFile(join(DIST, '.nojekyll'), '', 'utf8');

    const generated = join(ROOT, 'demo', 'src', 'generated', 'sources.json');
    if (!existsSync(generated)) {
        throw new Error('sources.json is missing. Run scripts/generate-sources.mjs first.');
    }
    await cp(generated, join(DIST, 'sources.json'));

    const assetBytes = await directorySize(join(DIST, 'assets'));
    const manifestBytes = (await stat(join(DIST, 'sources.json'))).size;
    console.log(
        `assets: ${(assetBytes / 1024 / 1024).toFixed(1)} MB · ` +
        `sources.json: ${(manifestBytes / 1024).toFixed(0)} KB`
    );
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
