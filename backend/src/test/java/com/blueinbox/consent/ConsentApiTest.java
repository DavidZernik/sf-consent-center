package com.blueinbox.consent;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.util.List;
import java.util.Map;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class ConsentApiTest {
    private final ObjectMapper json = new ObjectMapper();
    private ConsentService service;
    private MockMvc api;
    private String contact;
    private JsonNode preference;

    @BeforeEach void setup() throws Exception {
        service = new ConsentService(json);
        api = MockMvcBuilders.standaloneSetup(new ConsentController(service)).build();
        preference = service.summaries(null, null).get(0);
        contact = preference.path("contactId").asText();
    }

    private JsonNode change(String channel, Object optIn) {
        return json.valueToTree(Map.of("channel", channel, "optIn", optIn));
    }
    private JsonNode request(JsonNode... changes) throws Exception {
        return json.valueToTree(Map.of("changesJson", json.writeValueAsString(changes), "source", "Service Console"));
    }

    @Test void restReadsPreserveTheLwcContractAndFilterCaseInsensitively() throws Exception {
        String term = preference.path("contactName").asText().toUpperCase();
        api.perform(get("/api/consents").param("searchTerm", term).param("channel", preference.path("channel").asText()))
                .andExpect(status().isOk()).andExpect(jsonPath("$[0].contactId").value(contact));
        api.perform(get("/api/contacts/{id}/consent", contact)).andExpect(status().isOk())
                .andExpect(jsonPath("$.preferences").isArray()).andExpect(jsonPath("$.history").isArray());
    }

    @Test void saveWritesAuditHistoryAndNoOpIsIdempotent() throws Exception {
        String channel = preference.path("channel").asText();
        boolean next = !preference.path("optIn").asBoolean();
        int before = service.detail(contact).path("history").size();
        var payload = request(change(channel, next));
        api.perform(post("/api/contacts/{id}/preferences", contact).contentType(MediaType.APPLICATION_JSON)
                        .content(payload.toString())).andExpect(status().isOk());
        var detail = service.detail(contact);
        assertEquals(before + 1, detail.path("history").size());
        assertEquals(next ? "Opted In" : "Opted Out", detail.path("history").get(0).path("newValue").asText());
        assertTrue(service.summaries(null, channel).findValuesAsText("syncStatus").contains("Pending"));
        service.save(contact, payload);
        assertEquals(before + 1, service.detail(contact).path("history").size());
    }

    @Test void invalidBatchDoesNotPartiallyMutateConsentOrAuditRecords() throws Exception {
        JsonNode before = service.detail(contact);
        JsonNode logs = service.logs(null);
        var payload = request(change(preference.path("channel").asText(), !preference.path("optIn").asBoolean()), change("Carrier pigeon", true));
        api.perform(post("/api/contacts/{id}/preferences", contact).contentType(MediaType.APPLICATION_JSON)
                .content(payload.toString())).andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.body.message").value("Unsupported channel: Carrier pigeon"));
        assertEquals(before, service.detail(contact));
        assertEquals(logs, service.logs(null));
    }

    @Test void rejectsNonBooleanConsentDuplicateChannelsAndUnknownContacts() throws Exception {
        assertThrows(IllegalArgumentException.class, () -> service.save(contact, request(change("Email", "true"))));
        assertThrows(IllegalArgumentException.class, () -> service.save(contact, request(change("Email", true), change("Email", false))));
        api.perform(get("/api/contacts/unknown/consent")).andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.body.message").isString());
        api.perform(post("/api/contacts/{id}/preferences", contact).contentType(MediaType.APPLICATION_JSON).content("{"))
                .andExpect(status().isBadRequest()).andExpect(jsonPath("$.body.message").value("Request body must be valid JSON."));
    }

    @Test void mostRestrictiveWinsEvenWhenTheMajorityOptsIn() {
        var source = json.valueToTree(List.of(Map.of("channel", "Email", "optIn", true),
                Map.of("channel", "Email", "optIn", true), Map.of("channel", "Email", "optIn", false),
                Map.of("channel", "SMS", "optIn", true)));
        var resolved = service.resolve(source);
        assertFalse(resolved.get(0).path("optIn").asBoolean());
        assertTrue(resolved.get(0).path("isConflicted").asBoolean());
        assertEquals(1, resolved.get(0).path("sourcesAgreeing").asInt());
        assertTrue(resolved.get(1).path("optIn").asBoolean());
        assertFalse(resolved.get(1).path("isConflicted").asBoolean());
        assertEquals("The only source on record is opt-in.", resolved.get(1).path("reason").asText());
        assertTrue(service.resolve(json.createArrayNode()).isEmpty());
    }

    @Test void retrySkipsSyncedPreferencesOnSecondAttempt() throws Exception {
        service.save(contact, request(change(preference.path("channel").asText(), !preference.path("optIn").asBoolean())));
        String log = service.logs(null).get(0).path("logId").asText();
        var payload = json.valueToTree(Map.of("logIds", List.of(log)));
        api.perform(post("/api/sync-logs/retry").contentType(MediaType.APPLICATION_JSON).content(payload.toString()))
                .andExpect(status().isOk()).andExpect(jsonPath("$.queued").value(1));
        assertEquals(0, service.retry(payload).path("queued").asInt());
        assertEquals(1, service.retry(payload).path("skipped").asInt());
        assertEquals(0, service.retry(json.valueToTree(Map.of("logIds", List.of("missing")))).path("queued").asInt());
    }
}
