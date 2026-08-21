/**
 * Domain exception for the Consent Center. Kept separate from AuraHandledException so
 * service-layer callers can catch a meaningful type; the service boundary is the only
 * place that translates to AuraHandledException for the UI.
 */
public with sharing class ConsentCenterException extends Exception {}
