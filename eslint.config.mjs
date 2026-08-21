import js from '@eslint/js';
import lwc from '@lwc/eslint-plugin-lwc';
import globals from 'globals';
import babelParser from '@babel/eslint-parser';

/**
 * ESLint flat config.
 *
 * The rules that matter here are the LWC-specific ones. Several of them catch mistakes that are
 * invisible in review and only show up as a memory leak or a silently dead handler in production:
 *
 *   - valid-api            an @api name that is not callable from a parent (the exact bug that
 *                          made every toast in this app silently do nothing)
 *   - no-leaky-event-listeners  a window listener added without a matching removal
 *   - no-async-operation    setTimeout/setInterval without cleanup
 *   - no-inner-html         innerHTML outside the sanctioned lwc:dom="manual" escape hatch
 *   - no-document-query     reaching outside the component's own shadow root
 */
export default [
    {
        ignores: ['dist/**', 'node_modules/**', 'demo/src/generated/**', '**/__tests__/**']
    },
    js.configs.recommended,
    {
        files: ['force-app/main/default/lwc/**/*.js', 'demo/src/modules/**/*.js'],
        languageOptions: {
            ecmaVersion: 2023,
            sourceType: 'module',
            globals: { ...globals.browser },
            // LWC uses decorators (@api, @track, @wire), which the default parser cannot read.
            parser: babelParser,
            parserOptions: {
                requireConfigFile: false,
                babelOptions: {
                    plugins: [['@babel/plugin-proposal-decorators', { version: 'legacy' }]]
                }
            }
        },
        plugins: { '@lwc/lwc': lwc },
        rules: {
            '@lwc/lwc/valid-api': 'error',
            '@lwc/lwc/valid-track': 'error',
            '@lwc/lwc/no-api-reassignments': 'error',
            '@lwc/lwc/no-attributes-during-construction': 'error',
            '@lwc/lwc/no-deprecated': 'error',
            '@lwc/lwc/no-document-query': 'error',
            '@lwc/lwc/no-dupe-class-members': 'error',
            '@lwc/lwc/no-leaky-event-listeners': 'error',
            '@lwc/lwc/no-inner-html': 'error',
            '@lwc/lwc/prefer-custom-event': 'error',
            '@lwc/lwc/consistent-component-name': 'error',
            '@lwc/lwc/no-async-operation': 'warn',
            'no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
            'no-console': ['warn', { allow: ['warn', 'error'] }]
        }
    },
    {
        // The bootstrap is not a component. It mounts the app into the page, so document-level
        // queries are exactly right here and the component rules do not apply.
        files: ['demo/src/index.js'],
        languageOptions: {
            ecmaVersion: 2023,
            sourceType: 'module',
            globals: { ...globals.browser }
        },
        rules: {
            'no-unused-vars': ['error', { argsIgnorePattern: '^_' }]
        }
    },
    {
        // Build tooling and the demo data layer run in Node, not the browser.
        files: ['scripts/**/*.mjs', 'demo/src/mocks/**/*.js', '*.mjs'],
        languageOptions: {
            ecmaVersion: 2023,
            sourceType: 'module',
            globals: { ...globals.node, ...globals.browser }
        },
        rules: {
            'no-unused-vars': ['error', { argsIgnorePattern: '^_' }]
        }
    }
];
