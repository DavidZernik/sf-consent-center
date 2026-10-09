/** Same-origin Java mode: the Spring Boot jar serves this UI as well as its REST API. */
export function isJavaBackend() {
    return typeof window !== 'undefined' && new URLSearchParams(window.location.search).get('backend') === 'java';
}

export async function javaRequest(method, params = {}) {
    const contact = encodeURIComponent(params.contactId || '');
    const routes = {
        getConsentSummaries: ['/api/consents', { searchTerm: params.searchTerm, channel: params.channel }],
        getConsentDetail: [`/api/contacts/${contact}/consent`],
        savePreferences: [`/api/contacts/${contact}/preferences`, null, params],
        getSyncLogs: ['/api/sync-logs', { status: params.status }],
        retrySync: ['/api/sync-logs/retry', null, params],
        getUnifiedProfile: [`/api/contacts/${contact}/unified-profile`]
    };
    const [path, query, body] = routes[method];
    const search = new URLSearchParams();
    Object.entries(query || {}).forEach(([key, value]) => {
        if (value !== undefined && value !== null) search.set(key, value);
    });
    try {
        const response = await fetch(path + (search.size ? `?${search}` : ''), body ? {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
        } : {});
        const result = await response.json();
        if (!response.ok) throw { ...result, status: response.status };
        return result;
    } catch (error) {
        if (error.body?.message) throw error;
        throw { body: { message: 'The Java backend is unavailable. Start the Spring Boot app on port 8081.' } };
    }
}
