/**
 * Marketing Cloud SOAP client for the Subscriber object.
 *
 * Why SOAP when the rest of this integration is REST: Marketing Cloud's REST API can write rows
 * into a Data Extension, but it cannot set a Subscriber's account-level status on the All
 * Subscribers list. A global unsubscribe — the one that suppresses a person across every send in
 * the account, which is what a legal opt-out actually means — is only exposed through the SOAP
 * Subscriber object. Using REST here would produce a consent record that looks correct and does
 * not actually stop the mail.
 *
 * The envelope is built by hand rather than from a generated WSDL stub. The generated Apex for
 * the Marketing Cloud WSDL exceeds the class size limit, so hand-rolling the two operations this
 * app needs is the standard workaround.
 */
public with sharing class SfmcSoapClient {
    private static final String SOAP_ACTION_UPDATE = 'Update';
    private static final Integer CALLOUT_TIMEOUT_MS = 60000;

    /** Marketing Cloud subscriber statuses that matter to consent. */
    public enum SubscriberStatus { ACTIVE, UNSUBSCRIBED, HELD }

    public class SoapResult {
        public Boolean success;
        public String statusCode;
        public String statusMessage;
        public String subscriberKey;
        public Boolean retryable;
        public Long durationMs;
    }

    /**
     * Sets a subscriber's account-level status.
     *
     * @param subscriberKey The subscriber key, which this application keys on the Contact id.
     * @param emailAddress  Required by Marketing Cloud on an upsert even when only status changes.
     * @param status        Target status.
     */
    public SoapResult updateSubscriberStatus(String subscriberKey, String emailAddress, SubscriberStatus status) {
        if (String.isBlank(subscriberKey)) {
            throw new ConsentCenterException('A subscriber key is required.');
        }
        if (String.isBlank(emailAddress)) {
            throw new ConsentCenterException('Marketing Cloud rejects a Subscriber upsert with no email address.');
        }

        Long startedAt = System.currentTimeMillis();
        SfmcAuth.Token token = SfmcAuth.getToken();

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:SFMC_Soap/Service.asmx');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=utf-8');
        req.setHeader('SOAPAction', SOAP_ACTION_UPDATE);
        req.setTimeout(CALLOUT_TIMEOUT_MS);
        req.setBody(buildUpdateEnvelope(token.accessToken, subscriberKey, emailAddress, status));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (System.CalloutException e) {
            return failure(null, 'Callout failed: ' + e.getMessage(), true, System.currentTimeMillis() - startedAt);
        }

        Long elapsed = System.currentTimeMillis() - startedAt;

        // SOAP reports application errors inside a 200 response, so the status code alone is
        // never enough to decide whether the call worked.
        if (res.getStatusCode() == 401) {
            SfmcAuth.invalidate();
            return failure('401', 'Access token rejected.', true, elapsed);
        }
        if (res.getStatusCode() >= 500) {
            return failure(String.valueOf(res.getStatusCode()), 'Marketing Cloud SOAP endpoint error.', true, elapsed);
        }
        if (res.getStatusCode() != 200) {
            return failure(String.valueOf(res.getStatusCode()), res.getBody(), false, elapsed);
        }

        SoapResult result = parseUpdateResponse(res.getBody());
        result.subscriberKey = subscriberKey;
        result.durationMs = elapsed;
        return result;
    }

    /**
     * Builds the Update envelope.
     *
     * SaveAction "UpdateAdd" is an upsert: update the subscriber if the key exists, create it
     * otherwise. Without it, a first-time opt-out for someone not yet in the account fails.
     */
    @TestVisible
    private static String buildUpdateEnvelope(
        String accessToken,
        String subscriberKey,
        String emailAddress,
        SubscriberStatus status
    ) {
        // Every interpolated value is XML-escaped: an apostrophe in an email address would
        // otherwise produce a malformed envelope, and a crafted value could inject elements.
        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" '
            + 'xmlns:par="http://exacttarget.com/wsdl/partnerAPI">'
            + '<soapenv:Header><fueloauth xmlns="http://exacttarget.com">'
            + escapeXml(accessToken)
            + '</fueloauth></soapenv:Header>'
            + '<soapenv:Body>'
            + '<par:UpdateRequest>'
            + '<par:Options>'
            + '<par:SaveOptions><par:SaveOption>'
            + '<par:PropertyName>*</par:PropertyName>'
            + '<par:SaveAction>UpdateAdd</par:SaveAction>'
            + '</par:SaveOption></par:SaveOptions>'
            + '</par:Options>'
            + '<par:Objects xsi:type="par:Subscriber" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            + '<par:SubscriberKey>' + escapeXml(subscriberKey) + '</par:SubscriberKey>'
            + '<par:EmailAddress>' + escapeXml(emailAddress) + '</par:EmailAddress>'
            + '<par:Status>' + statusLabel(status) + '</par:Status>'
            + '</par:Objects>'
            + '</par:UpdateRequest>'
            + '</soapenv:Body></soapenv:Envelope>';
    }

    /**
     * Reads the OverallStatus and per-object Result out of the response envelope.
     *
     * Parsed with Dom.Document rather than by string matching, because a namespace prefix change
     * on the Marketing Cloud side would silently break substring parsing and quietly report
     * every unsubscribe as successful.
     */
    @TestVisible
    private static SoapResult parseUpdateResponse(String body) {
        SoapResult result = new SoapResult();
        result.retryable = false;

        try {
            Dom.Document document = new Dom.Document();
            document.load(body);
            Dom.XmlNode envelope = document.getRootElement();

            Dom.XmlNode statusNode = findDescendant(envelope, 'OverallStatus');
            Dom.XmlNode codeNode = findDescendant(envelope, 'StatusCode');
            Dom.XmlNode messageNode = findDescendant(envelope, 'StatusMessage');

            String overall = statusNode == null ? null : statusNode.getText();
            result.statusCode = codeNode == null ? null : codeNode.getText();
            result.statusMessage = messageNode == null ? null : messageNode.getText();

            // Marketing Cloud reports "OK" for full success and "Error" or "Has Errors" otherwise.
            result.success = 'OK'.equalsIgnoreCase(overall);
            if (!result.success && String.isBlank(result.statusMessage)) {
                result.statusMessage = 'Marketing Cloud returned status: ' + overall;
            }
            return result;
        } catch (Exception e) {
            result.success = false;
            result.statusMessage = 'Unparseable SOAP response: ' + e.getMessage();
            result.retryable = true;
            return result;
        }
    }

    /** Depth-first search for a node by local name, ignoring namespace prefixes. */
    private static Dom.XmlNode findDescendant(Dom.XmlNode node, String localName) {
        for (Dom.XmlNode child : node.getChildElements()) {
            if (localName.equals(child.getName())) {
                return child;
            }
            Dom.XmlNode found = findDescendant(child, localName);
            if (found != null) {
                return found;
            }
        }
        return null;
    }

    private static String statusLabel(SubscriberStatus status) {
        switch on status {
            when UNSUBSCRIBED {
                return 'Unsubscribed';
            }
            when HELD {
                return 'Held';
            }
            when else {
                return 'Active';
            }
        }
    }

    @TestVisible
    private static String escapeXml(String value) {
        if (String.isBlank(value)) {
            return '';
        }
        return value
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;')
            .replace('\'', '&apos;');
    }

    private SoapResult failure(String code, String message, Boolean retryable, Long elapsed) {
        SoapResult result = new SoapResult();
        result.success = false;
        result.statusCode = code;
        result.statusMessage = message;
        result.retryable = retryable;
        result.durationMs = elapsed;
        return result;
    }
}
