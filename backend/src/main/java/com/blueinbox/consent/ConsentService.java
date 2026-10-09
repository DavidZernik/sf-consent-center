package com.blueinbox.consent;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.springframework.core.io.ClassPathResource;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.time.Instant;
import java.util.*;
import java.util.stream.StreamSupport;

/** Local portfolio data service. Fictional data; no outbound Salesforce calls or persistent storage. */
@Service
public class ConsentService {
    private final ObjectMapper json;
    private final ObjectNode store;
    private final Set<String> channels = new LinkedHashSet<>();
    private long sequence = 90000;

    public ConsentService(ObjectMapper json) throws IOException {
        this.json = json;
        try (var input = new ClassPathResource("seed.json").getInputStream()) {
            store = (ObjectNode) json.readTree(input);
        }
        store.path("channels").forEach(c -> channels.add(c.asText()));
    }

    private ArrayNode rows(String key) { return (ArrayNode) store.get(key); }
    private boolean matches(JsonNode row, String key, String value) { return row.path(key).asText().equals(value); }
    private String id(String prefix) { return prefix + String.format("%012d", ++sequence); }
    private List<JsonNode> preferences(String contactId) {
        return StreamSupport.stream(rows("preferences").spliterator(), false)
                .filter(r -> matches(r, "contactId", contactId)).toList();
    }

    public synchronized ArrayNode summaries(String searchTerm, String channel) {
        String term = searchTerm == null ? "" : searchTerm.trim().toLowerCase(Locale.ROOT);
        if (channel != null && !channel.equals("All") && !channels.contains(channel))
            throw new IllegalArgumentException("Unsupported channel: " + channel);
        var result = json.createArrayNode();
        StreamSupport.stream(rows("preferences").spliterator(), false)
                .filter(r -> channel == null || channel.equals("All") || matches(r, "channel", channel))
                .filter(r -> r.path("contactName").asText().toLowerCase(Locale.ROOT).contains(term)
                        || r.path("email").asText("").toLowerCase(Locale.ROOT).contains(term))
                .sorted(Comparator.comparing((JsonNode r) -> r.path("lastChanged").asText()).reversed())
                .limit(200).forEach(r -> result.add(r.deepCopy()));
        return result;
    }

    public synchronized ObjectNode detail(String contactId) {
        requireContact(contactId);
        var prefs = preferences(contactId);
        var result = json.createObjectNode().put("contactId", contactId);
        for (String key : List.of("contactName", "email", "lifecycleStage")) result.set(key, prefs.getFirst().get(key));
        var fields = result.putArray("preferences");
        for (String channel : channels) {
            prefs.stream().filter(r -> matches(r, "channel", channel)).findFirst().ifPresent(r -> {
                var pref = json.createObjectNode();
                for (String key : List.of("preferenceId", "channel", "optIn", "consentSource", "lastChanged", "syncStatus"))
                    pref.set(key, r.get(key));
                fields.add(pref);
            });
        }
        var history = result.putArray("history");
        StreamSupport.stream(rows("history").spliterator(), false)
                .filter(r -> matches(r, "contactId", contactId))
                .sorted(Comparator.comparing((JsonNode r) -> r.path("changedAt").asText()).reversed())
                .forEach(r -> history.add(r.deepCopy()));
        return result.deepCopy();
    }

    private void requireContact(String contactId) {
        if (contactId == null || contactId.isBlank()) throw new IllegalArgumentException("A contact is required.");
        if (preferences(contactId).isEmpty()) throw new IllegalArgumentException("No consent records found for that contact.");
    }

    /** Validate the entire batch first; invalid changes never partially alter consent or history. */
    public synchronized ObjectNode save(String contactId, JsonNode request) {
        requireContact(contactId);
        if (request == null || !request.path("changesJson").isTextual())
            throw new IllegalArgumentException("No preference changes were supplied.");
        JsonNode changes;
        try { changes = json.readTree(request.path("changesJson").asText()); }
        catch (IOException e) { throw new IllegalArgumentException("Preference changes must be valid JSON."); }
        if (changes == null || !changes.isArray() || changes.isEmpty() || changes.size() > channels.size())
            throw new IllegalArgumentException("Supply between one and four preference changes.");
        Set<String> seen = new HashSet<>();
        for (JsonNode change : changes) {
            String channel = change.path("channel").asText();
            if (!channels.contains(channel)) throw new IllegalArgumentException("Unsupported channel: " + channel);
            if (!change.path("optIn").isBoolean()) throw new IllegalArgumentException("optIn must be true or false.");
            if (!seen.add(channel)) throw new IllegalArgumentException("Each channel may only appear once.");
        }
        String source = request.path("source").asText("Service Console").trim();
        if (source.isEmpty() || source.length() > 120) throw new IllegalArgumentException("Supply a source of 1–120 characters.");
        String now = Instant.now().toString();
        JsonNode sibling = preferences(contactId).getFirst();
        for (JsonNode change : changes) {
            String channel = change.path("channel").asText();
            boolean optIn = change.path("optIn").asBoolean();
            var existing = preferences(contactId).stream().filter(r -> matches(r, "channel", channel)).findFirst();
            if (existing.isPresent() && existing.get().path("optIn").asBoolean() == optIn) continue;
            var history = json.createObjectNode().put("historyId", id("a0B")).put("contactId", contactId)
                    .put("channel", channel).put("previousValue", existing.isEmpty() ? "None"
                            : existing.get().path("optIn").asBoolean() ? "Opted In" : "Opted Out")
                    .put("newValue", optIn ? "Opted In" : "Opted Out").put("changedByName", "Local demo user")
                    .put("changeSource", source).put("changedAt", now);
            rows("history").insert(0, history);
            ObjectNode pref;
            if (existing.isPresent()) pref = (ObjectNode) existing.get();
            else {
                pref = json.createObjectNode().put("preferenceId", id("a0A")).put("contactId", contactId).put("channel", channel);
                for (String key : List.of("contactName", "email", "lifecycleStage")) pref.set(key, sibling.get(key));
                rows("preferences").add(pref);
            }
            pref.put("optIn", optIn).put("consentSource", source).put("lastChanged", now).put("syncStatus", "Pending");
            rows("syncLogs").insert(0, json.createObjectNode().put("logId", id("a0C"))
                    .put("preferenceId", pref.path("preferenceId").asText()).put("contactName", pref.path("contactName").asText())
                    .put("channel", channel).put("status", "Retrying").put("attempt", 1)
                    .put("dataExtensionKey", "Consent_Preferences").putNull("statusCode")
                    .put("errorMessage", "Queued for simulated delivery.").putNull("durationMs").put("processedAt", now));
        }
        return detail(contactId);
    }

    public synchronized ArrayNode logs(String status) {
        var result = json.createArrayNode();
        StreamSupport.stream(rows("syncLogs").spliterator(), false)
                .filter(r -> status == null || status.equals("All") || matches(r, "status", status))
                .limit(100).forEach(r -> result.add(r.deepCopy()));
        return result;
    }

    /** Simulated delivery only. A second retry skips already-synced preferences. */
    public synchronized ObjectNode retry(JsonNode request) {
        JsonNode ids = request == null ? null : request.get("logIds");
        if (ids == null || !ids.isArray() || ids.size() > 100 || StreamSupport.stream(ids.spliterator(), false).anyMatch(i -> !i.isTextual()))
            throw new IllegalArgumentException("Supply up to 100 log IDs.");
        int queued = 0, skipped = 0;
        for (JsonNode logId : ids) {
            var log = StreamSupport.stream(rows("syncLogs").spliterator(), false)
                    .filter(r -> matches(r, "logId", logId.asText())).findFirst();
            var pref = log.flatMap(l -> StreamSupport.stream(rows("preferences").spliterator(), false)
                    .filter(r -> matches(r, "preferenceId", l.path("preferenceId").asText())).findFirst());
            if (pref.isEmpty() || matches(pref.get(), "syncStatus", "Synced")) { skipped++; continue; }
            ((ObjectNode) pref.get()).put("syncStatus", "Synced");
            ((ObjectNode) log.orElseThrow()).put("status", "Success").put("attempt", log.get().path("attempt").asInt(1) + 1)
                    .put("statusCode", 202).putNull("errorMessage").put("durationMs", 0).put("processedAt", Instant.now().toString());
            queued++;
        }
        return json.createObjectNode().put("queued", queued).put("skipped", skipped)
                .put("message", queued + " queued, " + skipped + " skipped.");
    }

    public synchronized ObjectNode unified(String contactId) {
        JsonNode profile = store.path("unifiedProfiles").get(contactId);
        if (profile == null) throw new IllegalArgumentException("No unified profile found for this contact. Identity Resolution may not have run yet.");
        ObjectNode result = profile.deepCopy();
        result.set("resolvedConsent", resolve(profile.path("sourceConsents")));
        return result;
    }

    /** Independently executes the same most-restrictive-wins policy as DataCloudService in Apex. */
    ArrayNode resolve(JsonNode consents) {
        Map<String, List<JsonNode>> grouped = new LinkedHashMap<>();
        consents.forEach(c -> grouped.computeIfAbsent(c.path("channel").asText(), key -> new ArrayList<>()).add(c));
        var result = json.createArrayNode();
        grouped.forEach((channel, entries) -> {
            long optedOut = entries.stream().filter(c -> !c.path("optIn").asBoolean()).count();
            int total = entries.size();
            boolean conflict = optedOut > 0 && optedOut < total;
            String position = optedOut == 0 ? "opt-in" : "opt-out";
            String reason = conflict ? optedOut + " of " + total + " sources recorded an opt-out. Most restrictive wins, so the unified profile is opted out."
                    : total == 1 ? "The only source on record is " + position + "." : "All " + total + " sources agree on " + position + ".";
            result.add(json.createObjectNode().put("channel", channel).put("optIn", optedOut == 0)
                    .put("isConflicted", conflict).put("sourcesTotal", total)
                    .put("sourcesAgreeing", optedOut == 0 ? total : optedOut).put("reason", reason));
        });
        return result;
    }
}
