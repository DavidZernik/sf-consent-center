import lwc from '@lwc/rollup-plugin';
import replace from '@rollup/plugin-replace';
import resolve from '@rollup/plugin-node-resolve';
import terser from '@rollup/plugin-terser';

const production = process.env.NODE_ENV !== 'development';

export default {
    input: 'demo/src/index.js',
    output: {
        dir: 'dist',
        entryFileNames: 'app.js',
        // Code-split rather than inlined. lightning-base-components loads its icon sprite
        // templates through dynamic imports, and those templates are the bulk of the bundle —
        // inlining them roughly quadrupled the initial download for icons most pages never use.
        chunkFileNames: 'chunks/[name]-[hash].js',
        format: 'esm',
        sourcemap: !production
    },
    // The base components package emits template warnings from its own internals. They are not
    // actionable from here and would bury real warnings from this project's code.
    onwarn(warning, warn) {
        if (warning.plugin === 'rollup-plugin-lwc-compiler') return;
        if (warning.code === 'CIRCULAR_DEPENDENCY') return;
        warn(warning);
    },
    plugins: [
        resolve(),
        lwc({
            rootDir: '.',
            // lightning-base-components uses lwc:component / lwc:is internally.
            enableDynamicComponents: true,
            experimentalDynamicDirective: true,
            enableLwcOn: true,
            // lightning-base-components calls attachInternals for form association. Synthetic
            // shadow has no native ElementInternals, so without this flag the combobox and the
            // datatable's boolean cells throw mid-render and silently stop painting.
            enableSyntheticElementInternals: true
        }),
        replace({
            preventAssignment: true,
            values: {
                // lightning-base-components carries Vite-era import.meta.env references, which
                // are undefined in a plain browser module.
                'import.meta.env.SSR': 'false',
                'process.env.NODE_ENV': JSON.stringify(production ? 'production' : 'development')
            }
        }),
        production &&
            terser({
                format: { comments: false },
                compress: { passes: 2 }
            })
    ].filter(Boolean)
};
