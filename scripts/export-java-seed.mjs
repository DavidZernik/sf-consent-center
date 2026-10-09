/** Export fictional fixtures and illustrative query traces from the same data as the LWC demo. */
import { mkdir, writeFile } from 'node:fs/promises';
import { CHANNELS } from '../demo/src/mocks/data/seed.js';
import { seedStore } from '../demo/src/mocks/apex/seedStore.js';
import { store } from '../demo/src/mocks/apex/apexRuntime.js';
import getUnifiedProfile from '../demo/src/mocks/apex/getUnifiedProfile.js';

seedStore();
const unifiedProfiles = {};
for (const contactId of Object.keys(store.unifiedProfiles)) {
    const profile = await getUnifiedProfile({ contactId });
    delete profile.resolvedConsent; // Java calculates these decisions itself.
    unifiedProfiles[contactId] = profile;
}
const output = new URL('../backend/src/main/resources/seed.json', import.meta.url);
await mkdir(new URL('.', output), { recursive: true });
await writeFile(output, JSON.stringify({ ...store, unifiedProfiles, channels: CHANNELS }, null, 2) + '\n');
console.log('Exported fictional Java fixtures. Query traces illustrate Apex SQL; they do not execute it.');
