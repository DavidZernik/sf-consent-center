package com.blueinbox.consent;

import com.fasterxml.jackson.databind.JsonNode;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.web.bind.annotation.*;
import java.util.Map;

@RestController
@RequestMapping("/api")
public class ConsentController {
    private final ConsentService service;
    public ConsentController(ConsentService service) { this.service = service; }

    @GetMapping("/health")
    public Map<String, String> health() { return Map.of("status", "ok", "backend", "Java 21 / Spring Boot"); }
    @GetMapping("/consents")
    public JsonNode summaries(@RequestParam(required = false) String searchTerm, @RequestParam(required = false) String channel) {
        return service.summaries(searchTerm, channel);
    }
    @GetMapping("/contacts/{contactId}/consent")
    public JsonNode detail(@PathVariable String contactId) { return service.detail(contactId); }
    @PostMapping("/contacts/{contactId}/preferences")
    public JsonNode save(@PathVariable String contactId, @RequestBody JsonNode request) { return service.save(contactId, request); }
    @GetMapping("/sync-logs")
    public JsonNode logs(@RequestParam(required = false) String status) { return service.logs(status); }
    @PostMapping("/sync-logs/retry")
    public JsonNode retry(@RequestBody JsonNode request) { return service.retry(request); }
    @GetMapping("/contacts/{contactId}/unified-profile")
    public JsonNode unified(@PathVariable String contactId) { return service.unified(contactId); }

    @ExceptionHandler(IllegalArgumentException.class)
    public ResponseEntity<?> invalid(IllegalArgumentException e) {
        return ResponseEntity.badRequest().body(Map.of("body", Map.of("message", e.getMessage())));
    }
    @ExceptionHandler(HttpMessageNotReadableException.class)
    public ResponseEntity<?> malformed() {
        return ResponseEntity.badRequest().body(Map.of("body", Map.of("message", "Request body must be valid JSON.")));
    }
}
