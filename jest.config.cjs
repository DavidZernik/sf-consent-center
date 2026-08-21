/**
 * Jest configuration for the Lightning Web Components.
 *
 * Built on @salesforce/sfdx-lwc-jest, the same runner an org-connected SFDX project uses. It
 * stubs every lightning/* base component automatically, which is why the component source needs
 * no test-specific branching.
 *
 * The moduleNameMapper entries below mirror lwc.config.json. They have to: components import
 * '@salesforce/apex/...' exactly as they would on the platform, and pointing those at the same
 * browser mocks means the demo, the org and the test suite all exercise one set of component
 * source against one contract.
 */
const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    // The demo shell is a real LWC namespace too, so its components are tested the same way.
    roots: ['<rootDir>/force-app/main/default/lwc', '<rootDir>/demo/src/modules'],
    moduleNameMapper: {
        ...jestConfig.moduleNameMapper,
        '^demo/(.+)$': '<rootDir>/demo/src/modules/demo/$1/$1',
        '^lightning/platformShowToastEvent$':
            '<rootDir>/demo/src/mocks/lightning/platformShowToastEvent.js',
        '^lightning/navigation$': '<rootDir>/demo/src/mocks/lightning/navigation.js',
        '^@salesforce/apex/ConsentService\\.getConsentSummaries$':
            '<rootDir>/demo/src/mocks/apex/getConsentSummaries.js',
        '^@salesforce/apex/ConsentService\\.getConsentDetail$':
            '<rootDir>/demo/src/mocks/apex/getConsentDetail.js',
        '^@salesforce/apex/ConsentService\\.savePreferences$':
            '<rootDir>/demo/src/mocks/apex/savePreferences.js',
        '^@salesforce/apex/ConsentService\\.getSyncLogs$':
            '<rootDir>/demo/src/mocks/apex/getSyncLogs.js',
        '^@salesforce/apex/ConsentService\\.retrySync$':
            '<rootDir>/demo/src/mocks/apex/retrySync.js',
        '^@salesforce/apex/DataCloudService\\.getUnifiedProfile$':
            '<rootDir>/demo/src/mocks/apex/getUnifiedProfile.js'
    },
    collectCoverageFrom: ['force-app/main/default/lwc/**/*.js', '!**/__tests__/**'],
    coverageReporters: ['text-summary', 'lcov']
};
