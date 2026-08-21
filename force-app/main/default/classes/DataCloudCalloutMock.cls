/**
 * Routing HTTP mock for the Data Cloud endpoints.
 *
 * Data Cloud query responses are column-oriented, so the helpers here build that shape from a
 * plain list of row maps. Hand-writing the metadata/data split in every test would be noise, and
 * getting placeInOrder wrong by hand is exactly the bug the parser is meant to catch.
 */
@IsTest
public class DataCloudCalloutMock implements HttpCalloutMock {
    /** Query responses, returned in order — one per call, last one repeating. */
    private final List<String> queryBodies;
    private final Integer queryStatus;
    private final Integer tokenStatus;

    public Integer queryCallCount = 0;
    public List<String> capturedSql = new List<String>();

    public DataCloudCalloutMock(List<String> queryBodies) {
        this(queryBodies, 200, 200);
    }

    public DataCloudCalloutMock(List<String> queryBodies, Integer queryStatus, Integer tokenStatus) {
        this.queryBodies = queryBodies == null ? new List<String>() : queryBodies;
        this.queryStatus = queryStatus;
        this.tokenStatus = tokenStatus;
    }

    public HTTPResponse respond(HTTPRequest request) {
        HttpResponse response = new HttpResponse();
        response.setHeader('Content-Type', 'application/json');

        if (request.getEndpoint().contains('/services/a360/token')) {
            response.setStatusCode(tokenStatus);
            response.setBody(tokenStatus == 200
                ? '{"access_token":"dc-token","instance_url":"tenant.c360a.salesforce.com","expires_in":1800,"token_type":"Bearer"}'
                : '{"error":"invalid_grant"}');
            return response;
        }

        // Capture the SQL so tests can assert what was actually sent to the tenant.
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
        capturedSql.add((String) body.get('sql'));

        Integer index = Math.min(queryCallCount, queryBodies.size() - 1);
        queryCallCount++;
        response.setStatusCode(queryStatus);
        response.setBody(queryBodies.isEmpty() ? emptyResult() : queryBodies[index]);
        return response;
    }

    /* --------------------------------------------------------------- Body builders */

    /**
     * Builds a v2 query response from row maps.
     *
     * Column order is taken from the first row's key order and applied to every row, which is
     * what the real API does.
     */
    public static String resultOf(List<Map<String, Object>> rows) {
        if (rows == null || rows.isEmpty()) {
            return emptyResult();
        }
        List<String> columns = new List<String>(rows[0].keySet());

        List<String> metadataEntries = new List<String>();
        for (Integer i = 0; i < columns.size(); i++) {
            metadataEntries.add(
                '"' + columns[i] + '":{"placeInOrder":' + i + ',"type":"VARCHAR","typeCode":12}'
            );
        }

        List<String> dataRows = new List<String>();
        for (Map<String, Object> row : rows) {
            List<String> values = new List<String>();
            for (String column : columns) {
                Object value = row.get(column);
                values.add(value == null ? 'null' : JSON.serialize(value));
            }
            dataRows.add('[' + String.join(values, ',') + ']');
        }

        return '{"data":[' + String.join(dataRows, ',') + '],'
            + '"metadata":{' + String.join(metadataEntries, ',') + '},'
            + '"rowCount":' + rows.size() + ',"done":true}';
    }

    public static String emptyResult() {
        return '{"data":[],"metadata":{},"rowCount":0,"done":true}';
    }

    /** The identity-graph response: two CRM records resolving to one unified individual. */
    public static String identityGraphResult(Id contactId) {
        return resultOf(new List<Map<String, Object>>{
            new Map<String, Object>{
                'UnifiedRecordId__c' => 'UNI-0001',
                'SourceRecordId__c' => String.valueOf(contactId),
                'SourceSystemName__c' => 'Salesforce CRM',
                'MatchConfidence__c' => 1.0,
                'ssot__FirstName__c' => 'Dana',
                'ssot__LastName__c' => 'Reyes',
                'ssot__EmailAddress__c' => 'dana.reyes@example.invalid',
                'ssot__LastModifiedDate__c' => '2026-07-01T10:15:00.000Z'
            },
            new Map<String, Object>{
                'UnifiedRecordId__c' => 'UNI-0001',
                'SourceRecordId__c' => 'POS-88213',
                'SourceSystemName__c' => 'Point of Sale',
                'MatchConfidence__c' => 0.92,
                'ssot__FirstName__c' => 'Dana',
                'ssot__LastName__c' => 'Reyes',
                'ssot__EmailAddress__c' => 'dana.reyes@example.invalid',
                'ssot__LastModifiedDate__c' => '2026-06-11T08:02:00.000Z'
            }
        });
    }

    /** Consent rows where the two sources disagree on Email — the conflict case. */
    public static String conflictingConsentResult(Id contactId) {
        return resultOf(new List<Map<String, Object>>{
            new Map<String, Object>{
                'ssot__PartyIdentificationId__c' => String.valueOf(contactId),
                'ssot__ContactPointType__c' => 'Email',
                'ssot__ConsentStatus__c' => 'OptIn',
                'ssot__EffectiveFromDate__c' => '2026-05-01T00:00:00.000Z',
                'ssot__DataSourceName__c' => 'Salesforce CRM'
            },
            new Map<String, Object>{
                'ssot__PartyIdentificationId__c' => 'POS-88213',
                'ssot__ContactPointType__c' => 'Email',
                'ssot__ConsentStatus__c' => 'OptOut',
                'ssot__EffectiveFromDate__c' => '2026-06-20T00:00:00.000Z',
                'ssot__DataSourceName__c' => 'Point of Sale'
            },
            new Map<String, Object>{
                'ssot__PartyIdentificationId__c' => String.valueOf(contactId),
                'ssot__ContactPointType__c' => 'SMS',
                'ssot__ConsentStatus__c' => 'OptIn',
                'ssot__EffectiveFromDate__c' => '2026-05-01T00:00:00.000Z',
                'ssot__DataSourceName__c' => 'Salesforce CRM'
            }
        });
    }

    public static String engagementInsightResult() {
        return resultOf(new List<Map<String, Object>>{
            new Map<String, Object>{
                'Engagement_Score__c' => 82.4,
                'Last_Engagement_Date__c' => '2026-08-14T19:40:00.000Z',
                'Email_Opens_90d__c' => 27,
                'Clicks_90d__c' => 9
            }
        });
    }
}
