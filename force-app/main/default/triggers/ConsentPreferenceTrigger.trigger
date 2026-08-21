/**
 * One trigger per object, no logic inside it.
 *
 * Everything the trigger does lives in ConsentPreferenceTriggerHandler so it can be unit tested
 * directly, and so the execution order is defined by one readable switch rather than by the
 * order Salesforce happens to load multiple triggers on the same object.
 */
trigger ConsentPreferenceTrigger on Consent_Preference__c (
    before insert,
    before update,
    after insert,
    after update
) {
    ConsentPreferenceTriggerHandler.run(
        Trigger.operationType,
        Trigger.new,
        Trigger.oldMap
    );
}
