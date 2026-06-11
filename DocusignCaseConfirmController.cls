public with sharing class DocusignCaseConfirmController {

    public Id caseId { get; private set; }
    public String caseNumber { get; private set; }

    public Id accountId { get; private set; }
    public String accountName { get; private set; }

    public Id contactId { get; private set; }
    public String contactName { get; private set; }
    public String contactEmail { get; private set; }

    public Id controleurId { get; private set; }
    public String controleurName { get; private set; }
    public String controleurEmail { get; private set; }

    public Id contentVersionId { get; private set; }
    public String documentTitle { get; private set; }
    public String documentExtension { get; private set; }
    public Integer documentSize { get; private set; }
    public Datetime documentCreatedDate { get; private set; }

    // Wordt bij open vastgelegd en bij send vergeleken (optimistic lock).
    public Id expectedContentVersionId { get; set; }

    public List<String> errors { get; private set; }

    public Boolean sent { get; private set; }
    public String successMessage { get; private set; }

    public DocusignCaseConfirmController(ApexPages.StandardController standardController) {
        this.caseId = standardController.getId();
        this.errors = new List<String>();
        this.sent = false;

        loadData();

        this.expectedContentVersionId = this.contentVersionId;
    }

    private void loadData() {
        errors = new List<String>();

        caseNumber = null;
        accountId = null;  accountName = null;
        contactId = null;  contactName = null;  contactEmail = null;
        controleurId = null;  controleurName = null;  controleurEmail = null;
        contentVersionId = null;  documentTitle = null;  documentExtension = null;
        documentSize = null;  documentCreatedDate = null;

        if (caseId == null) {
            errors.add('Case Id ontbreekt.');
            return;
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
            errors.add('Case niet gevonden of geen toegang.');
            return;
        }

        Case caseRecord = cases[0];

        caseNumber  = caseRecord.CaseNumber;
        accountId   = caseRecord.AccountId;
        accountName = (caseRecord.Account != null) ? caseRecord.Account.Name : null;
        contactId   = caseRecord.ContactId;
        contactName = (caseRecord.Contact != null) ? caseRecord.Contact.Name : null;
        contactEmail= (caseRecord.Contact != null) ? caseRecord.Contact.Email : null;

        if (accountId == null) {
            errors.add('Account ontbreekt op de Case.');
        }

        if (contactId == null) {
            errors.add('Contact ontbreekt op de Case.');
        } else if (String.isBlank(contactEmail)) {
            errors.add('Het Contact heeft geen e-mailadres.');
        }

        if (caseRecord.Ter_controle_van__c == null) {
            errors.add('Het veld Ter controle van is niet gevuld op deze Case.');
        } else {
            controleurId = caseRecord.Ter_controle_van__c;
            if (controleurId.getSObjectType() != User.SObjectType) {
                errors.add('Het veld Ter controle van verwijst niet naar een Salesforce-gebruiker.');
            } else {
                List<User> controleurs = [
                    SELECT Id, Name, Email, IsActive
                    FROM User
                    WHERE Id = :controleurId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (controleurs.isEmpty()) {
                    errors.add('De controleur kon niet geladen worden.');
                } else {
                    controleurName  = controleurs[0].Name;
                    controleurEmail = controleurs[0].Email;
                    if (!controleurs[0].IsActive) {
                        errors.add('De controleur is geen actieve Salesforce-gebruiker.');
                    }
                    if (String.isBlank(controleurs[0].Email)) {
                        errors.add('De controleur heeft geen e-mailadres.');
                    }
                }
            }
        }

        List<ContentDocumentLink> linkedFiles = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :caseId
            WITH USER_MODE
        ];

        if (linkedFiles.isEmpty()) {
            errors.add('Geen Salesforce Files gevonden op deze Case.');
            return;
        }

        Set<Id> contentDocumentIds = new Set<Id>();
        for (ContentDocumentLink linkedFile : linkedFiles) {
            contentDocumentIds.add(linkedFile.ContentDocumentId);
        }

        // Casing consistent met de service: de service accepteert elke pdf via toLowerCase().
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
            errors.add('Geen PDF gevonden op deze Case. Upload eerst een PDF als Salesforce File.');
            return;
        }

        ContentVersion pdfVersion = pdfVersions[0];
        contentVersionId    = pdfVersion.Id;
        documentTitle       = pdfVersion.Title;
        documentExtension   = pdfVersion.FileExtension;
        documentSize        = pdfVersion.ContentSize;
        documentCreatedDate = pdfVersion.CreatedDate;

        if (pdfVersion.ContentSize == null || pdfVersion.ContentSize == 0) {
            errors.add('PDF heeft geen inhoud of ContentSize is 0.');
        }
    }

    public Boolean getCanSend()    { return !sent && errors != null && errors.isEmpty(); }
    public Boolean getDisableSend(){ return !getCanSend(); }
    public Boolean getHasErrors()  { return errors != null && !errors.isEmpty(); }

    public String getAccountLabel() {
        return String.isBlank(accountName) ? 'Niet gevuld' : accountName;
    }

    public String getContactLabel() {
        if (String.isBlank(contactName)) return 'Niet gevuld';
        return String.isBlank(contactEmail) ? contactName : contactName + ' <' + contactEmail + '>';
    }

    public String getControleurLabel() {
        if (String.isBlank(controleurName)) return 'Niet gevuld';
        return String.isBlank(controleurEmail) ? controleurName : controleurName + ' <' + controleurEmail + '>';
    }

    public String getDocumentLabel() {
        if (String.isBlank(documentTitle)) return 'Geen PDF gevonden';
        return documentTitle + '.' + documentExtension;
    }

    public PageReference sendEnvelope() {

        // Guard tegen dubbele submit binnen dezelfde view state.
        if (sent) {
            return null;
        }

        Id pdfIdAtModalOpen = expectedContentVersionId;

        loadData();

        if (getHasErrors()) {
            for (String errorMessage : errors) {
                ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, errorMessage));
            }
            return null;
        }

        // Optimistic lock: is de nieuwste PDF nog dezelfde als bij openen?
        if (pdfIdAtModalOpen != null && contentVersionId != pdfIdAtModalOpen) {
            ApexPages.addMessage(new ApexPages.Message(
                ApexPages.Severity.ERROR,
                'Het nieuwste PDF-document op deze Case is gewijzigd sinds het openen van dit scherm. Sluit dit scherm en open de actie opnieuw.'
            ));
            return null;
        }

        try {
            // Geef exact de gevalideerde PDF mee; de service zoekt niet zelf opnieuw.
            DocusignEnvelopeService.sendLatestPdfFromCase(caseId, contactId, contentVersionId);

            sent = true;
            successMessage = 'DocuSign-envelope is verzonden. Je kunt dit venster sluiten.';
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.CONFIRM, successMessage));
        } catch (Exception e) {
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }

        return null;
    }
}
