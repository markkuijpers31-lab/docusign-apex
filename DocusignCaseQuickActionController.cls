public with sharing class DocusignCaseQuickActionController {

    public class PreviewResponse {
        @AuraEnabled public Id caseId;
        @AuraEnabled public String caseNumber;

        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;

        @AuraEnabled public Id contactId;
        @AuraEnabled public String contactName;
        @AuraEnabled public String contactEmail;

        @AuraEnabled public Id controleurId;
        @AuraEnabled public String controleurName;
        @AuraEnabled public String controleurEmail;

        @AuraEnabled public Id contentVersionId;
        @AuraEnabled public Id contentDocumentId;
        @AuraEnabled public String documentTitle;
        @AuraEnabled public String documentExtension;
        @AuraEnabled public Long documentSize;
        @AuraEnabled public Datetime documentCreatedDate;

        @AuraEnabled public Boolean canSend;
        @AuraEnabled public List<String> errors;
    }

    @AuraEnabled(cacheable=true)
    public static PreviewResponse loadPreview(Id caseId) {

        PreviewResponse response = new PreviewResponse();
        response.caseId = caseId;
        response.canSend = true;
        response.errors = new List<String>();

        if (caseId == null) {
            response.canSend = false;
            response.errors.add('Case Id ontbreekt.');
            return response;
        }

        List<Case> cases = [
            SELECT Id, CaseNumber,
                   AccountId, Account.Name,
                   ContactId, Contact.Name, Contact.Email,
                   Ter_controle_van__c
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];

        if (cases.isEmpty()) {
            response.canSend = false;
            response.errors.add('Case niet gevonden of geen toegang.');
            return response;
        }

        Case caseRecord = cases[0];

        response.caseNumber  = caseRecord.CaseNumber;
        response.accountId   = caseRecord.AccountId;
        response.accountName = caseRecord.Account != null ? caseRecord.Account.Name : null;
        response.contactId   = caseRecord.ContactId;
        response.contactName = caseRecord.Contact != null ? caseRecord.Contact.Name : null;
        response.contactEmail= caseRecord.Contact != null ? caseRecord.Contact.Email : null;

        if (response.accountId == null) {
            response.canSend = false;
            response.errors.add('Account ontbreekt op de Case.');
        }

        if (response.contactId == null) {
            response.canSend = false;
            response.errors.add('Contact ontbreekt op de Case.');
        } else if (String.isBlank(response.contactEmail)) {
            response.canSend = false;
            response.errors.add('Het Contact heeft geen e-mailadres.');
        }

        if (caseRecord.Ter_controle_van__c == null) {
            response.canSend = false;
            response.errors.add('Het veld Ter controle van is niet gevuld op deze Case.');
        } else {
            Id controleurId = caseRecord.Ter_controle_van__c;

            if (controleurId.getSObjectType() != User.SObjectType) {
                response.canSend = false;
                response.errors.add('Het veld Ter controle van verwijst niet naar een Salesforce-gebruiker.');
            } else {
                List<User> controleurs = [
                    SELECT Id, Name, Email, IsActive
                    FROM User
                    WHERE Id = :controleurId
                    WITH USER_MODE
                    LIMIT 1
                ];

                if (!controleurs.isEmpty()) {
                    response.controleurId    = controleurs[0].Id;
                    response.controleurName  = controleurs[0].Name;
                    response.controleurEmail = controleurs[0].Email;

                    if (!controleurs[0].IsActive) {
                        response.canSend = false;
                        response.errors.add('De controleur is geen actieve Salesforce-gebruiker.');
                    }
                    if (String.isBlank(controleurs[0].Email)) {
                        response.canSend = false;
                        response.errors.add('De controleur heeft geen e-mailadres.');
                    }
                }
            }
        }

        List<ContentDocumentLink> linkedFiles = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseRecord.Id
            WITH USER_MODE
        ];

        if (linkedFiles.isEmpty()) {
            response.canSend = false;
            response.errors.add('Geen Salesforce Files gevonden op deze Case.');
            return response;
        }

        Set<Id> contentDocumentIds = new Set<Id>();
        for (ContentDocumentLink linkedFile : linkedFiles) {
            contentDocumentIds.add(linkedFile.ContentDocumentId);
        }

        List<ContentVersion> pdfVersions = [
            SELECT Id, Title, FileExtension, ContentDocumentId, ContentSize, CreatedDate
            FROM ContentVersion
            WHERE ContentDocumentId IN :contentDocumentIds
            AND IsLatest = true
            AND FileExtension IN ('pdf', 'PDF')
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (pdfVersions.isEmpty()) {
            response.canSend = false;
            response.errors.add('Geen PDF gevonden op deze Case. Upload eerst een PDF als Salesforce File.');
            return response;
        }

        ContentVersion pdfVersion = pdfVersions[0];

        response.contentVersionId   = pdfVersion.Id;
        response.contentDocumentId  = pdfVersion.ContentDocumentId;
        response.documentTitle      = pdfVersion.Title;
        response.documentExtension  = pdfVersion.FileExtension;
        response.documentSize       = pdfVersion.ContentSize;
        response.documentCreatedDate= pdfVersion.CreatedDate;

        if (pdfVersion.ContentSize == null || pdfVersion.ContentSize == 0) {
            response.canSend = false;
            response.errors.add('PDF heeft geen inhoud of ContentSize is 0.');
        }

        return response;
    }

    @AuraEnabled
    public static String sendEnvelope(Id caseId, Id contactId, Id expectedContentVersionId) {

        PreviewResponse preview = loadPreview(caseId);

        if (!preview.canSend) {
            throw new AuraHandledException(String.join(preview.errors, '\n'));
        }

        if (expectedContentVersionId != null && preview.contentVersionId != expectedContentVersionId) {
            throw new AuraHandledException(
                'Het laatst gekoppelde PDF-document is gewijzigd sinds het openen van deze modal. Sluit dit venster en probeer opnieuw.'
            );
        }

        // Geef exact de gevalideerde PDF mee (3-arg signatuur).
        DocusignEnvelopeService.sendLatestPdfFromCase(
            caseId,
            contactId,
            preview.contentVersionId
        );

        return 'DocuSign-envelope is verzonden.';
    }
}
