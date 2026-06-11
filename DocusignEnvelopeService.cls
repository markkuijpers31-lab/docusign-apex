public with sharing class DocusignEnvelopeService {

    private static final Integer MAX_CHECKBOX_ANCHORS = 200;

    /**
     * Custom exception zodat foutmeldingen in een Visualforce-context leesbaar
     * blijven. AuraHandledException levert buiten Aura/LWC vaak
     * "Script-thrown exception" op i.p.v. de echte boodschap.
     */
    public class DocusignSendException extends Exception {}

    /**
     * Publieke entry point. Bouwt de envelope en verstuurt deze.
     * De callout wordt overgeslagen tijdens tests, zodat de bouwlogica
     * gedekt kan worden zonder DocuSign aan te roepen.
     *
     * @param caseId            Case waaraan de envelope gekoppeld wordt.
     * @param contactId         Optioneel; valt terug op Case.ContactId.
     * @param contentVersionId  De ID van de reeds gevalideerde PDF (van de
     *                          confirm-pagina). De service zoekt NIET zelf
     *                          opnieuw de "nieuwste" PDF.
     */
    public static void sendLatestPdfFromCase(Id caseId, Id contactId, Id contentVersionId) {

        dfsle.Envelope envelope = buildEnvelope(caseId, contactId, contentVersionId);

        // Callout niet uitvoeren in testcontext; bouwlogica is wel gedekt.
        if (Test.isRunningTest()) {
            return;
        }

        dfsle.Envelope sentEnvelope = dfsle.EnvelopeService.sendEnvelope(envelope, true);
        System.debug(LoggingLevel.INFO, 'DocuSign Envelope verzonden: ' + sentEnvelope.docuSignId);
    }

    /**
     * Bouwt de volledige envelope. Geen callout. Apart gehouden voor testbaarheid.
     */
    @TestVisible
    private static dfsle.Envelope buildEnvelope(Id caseId, Id contactId, Id contentVersionId) {

        if (caseId == null) {
            throw new DocusignSendException('Case Id ontbreekt.');
        }
        if (contentVersionId == null) {
            throw new DocusignSendException('ContentVersion Id ontbreekt.');
        }

        Case caseRecord = loadCase(caseId);

        // ----- Signer 1: controleur -----
        // Niet Case Owner gebruiken; die kan een Queue zijn. Gebruik Ter_controle_van__c.
        if (caseRecord.Ter_controle_van__c == null) {
            throw new DocusignSendException('Het veld Ter controle van is niet gevuld op deze Case.');
        }

        Id controleurId = caseRecord.Ter_controle_van__c;
        if (controleurId.getSObjectType() != User.SObjectType) {
            throw new DocusignSendException('Het veld Ter controle van verwijst niet naar een Salesforce-gebruiker.');
        }

        User controleur = loadControleur(controleurId);
        if (!controleur.IsActive) {
            throw new DocusignSendException('De controleur is geen actieve Salesforce-gebruiker.');
        }
        if (String.isBlank(controleur.Email)) {
            throw new DocusignSendException('De controleur heeft geen e-mailadres.');
        }

        // ----- Signer 2: klantcontact -----
        Id signerContactId = (contactId != null) ? contactId : caseRecord.ContactId;
        if (signerContactId == null) {
            throw new DocusignSendException('Contact Id ontbreekt en deze Case heeft geen Contact gekoppeld.');
        }

        Contact signerContact = loadContact(signerContactId);
        if (String.isBlank(signerContact.Email)) {
            throw new DocusignSendException('Het gekozen Contact heeft geen e-mailadres.');
        }

        // ----- PDF valideren (exact de Id die de gebruiker bevestigde) -----
        ContentVersion pdfVersion = loadPdf(contentVersionId);

        // ----- E-mail teksten -----
        String caseLabel = 'Case ' + caseRecord.CaseNumber;

        String controleurSubject = 'Document ter controle in DocuSign - ' + caseLabel;
        String controleurMessage =
            'Beste ' + controleur.Name + ',\n\n' +
            'We hebben zojuist een document ter controle klaargezet in DocuSign. Gelieve deze te controleren en af te tekenen indien akkoord.\n\n' +
            'Mocht er iets niet kloppen, laat dit dan weten via salessupport@motrac.nl';

        String contactSubject = 'Officieel voorstel van Motrac - ' + caseLabel;
        String contactMessage =
            'Beste ' + signerContact.Name + ',\n\n' +
            'Hierbij delen wij ons officiële voorstel. U kunt middels onderstaande knop het document controleren en indien deze aan uw wensen voldoet ondertekenen.\n\n' +
            'Mocht u nog vragen hebben over dit document dan kunt u terecht bij uw contactpersoon.\n\n' +
            'Met vriendelijke groet,\n\n' +
            'Namens ' + controleur.Name + '\n' +
            'Motrac';

        // ----- Envelope -----
        dfsle.Envelope envelope = dfsle.EnvelopeService.getEmptyEnvelope(
            new dfsle.Entity(caseRecord.Id)
        );

        // RECIPIENT 1: Controleur (tekent eerst, krijgt \i1\)
        // ignoreIfNotPresent = false -> faalt luid als de anchor ontbreekt
        // i.p.v. de verplichte handtekening stil te droppen.
        dfsle.Tab controleurInitialTab = new dfsle.InitialHereTab()
            .withScale(1.0)
            .withRequired(true)
            .withAnchor(new dfsle.Tab.Anchor(
                '\\i1\\', false, false, 'right', false, false, 'pixels', 0, 0));

        dfsle.Recipient.EmailSettings controleurEmailSettings =
            new dfsle.Recipient.EmailSettings(null, null, controleurSubject, controleurMessage);

        dfsle.Recipient controleurRecipient = dfsle.Recipient.fromSource(
                controleur.Name, controleur.Email, null, 'Controleur', new dfsle.Entity(controleur.Id))
            .withRoutingOrder(1)
            .withEmailSettings(controleurEmailSettings)
            .withTabs(new List<dfsle.Tab>{ controleurInitialTab });

        // RECIPIENT 2: Contact / klant (tekent na controleur)
        // Verplichte tabs (\s2\, \n2\) -> ignoreIfNotPresent = false
        dfsle.Tab contactSignHereTab = new dfsle.SignHereTab()
            .withScale(1.0)
            .withRequired(true)
            .withAnchor(new dfsle.Tab.Anchor(
                '\\s2\\', false, false, 'right', false, false, 'pixels', -18, -28));

        dfsle.Tab contactNameTab = new dfsle.TextTab()
            .withRequired(true)
            .withName('contact_signer_name')
            .withDataLabel('contact_signer_name')
            .withAnchor(new dfsle.Tab.Anchor(
                '\\n2\\', false, false, 'right', false, false, 'pixels', -30, -8));

        // Optioneel referentieveld -> ignoreIfNotPresent = true mag blijven
        dfsle.Tab contactReferenceTab = new dfsle.TextTab()
            .withRequired(false)
            .withName('customer_reference')
            .withDataLabel('customer_reference')
            .withAnchor(new dfsle.Tab.Anchor(
                '\\ref2\\', false, false, 'right', true, true, 'pixels', -30, -8));

        List<dfsle.Tab> contactTabs = new List<dfsle.Tab>{
            contactSignHereTab,
            contactNameTab,
            contactReferenceTab
        };
        contactTabs.addAll(buildCheckboxTabsForContact(MAX_CHECKBOX_ANCHORS));

        dfsle.Recipient.EmailSettings contactEmailSettings =
            new dfsle.Recipient.EmailSettings(null, null, contactSubject, contactMessage);

        dfsle.Recipient contactRecipient = dfsle.Recipient.fromSource(
                signerContact.Name, signerContact.Email, null, 'CustomerSigner', new dfsle.Entity(signerContact.Id))
            .withRoutingOrder(2)
            .withEmailSettings(contactEmailSettings)
            .withTabs(contactTabs);

        envelope = envelope.withRecipients(new List<dfsle.Recipient>{
            controleurRecipient, contactRecipient
        });

        // Document: GEEN AcroForm-transformatie. Checkboxen via expliciete anchors.
        List<dfsle.Document> docusignDocuments = dfsle.DocumentService.getDocuments(
            ContentVersion.getSObjectType(),
            new Set<Id>{ pdfVersion.Id }
        );
        if (docusignDocuments.isEmpty()) {
            throw new DocusignSendException('DocuSign kon geen document laden uit de gekoppelde PDF.');
        }

        envelope = envelope.withDocuments(new List<dfsle.Document>{ docusignDocuments[0] });
        envelope = envelope.withEmail(
            'DocuSign voorstel - ' + caseLabel,
            'Dit document wordt via DocuSign ter controle en ondertekening aangeboden.'
        );

        return envelope;
    }

    // ------------------------------------------------------------------
    // SOQL helpers (allemaal WITH USER_MODE voor FLS/sharing-enforcement)
    // ------------------------------------------------------------------

    private static Case loadCase(Id caseId) {
        List<Case> cases = [
            SELECT Id, CaseNumber, Subject, ContactId, Ter_controle_van__c
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];
        if (cases.isEmpty()) {
            throw new DocusignSendException('Case niet gevonden of geen toegang.');
        }
        return cases[0];
    }

    private static User loadControleur(Id controleurId) {
        List<User> users = [
            SELECT Id, Name, Email, IsActive
            FROM User
            WHERE Id = :controleurId
            WITH USER_MODE
            LIMIT 1
        ];
        if (users.isEmpty()) {
            throw new DocusignSendException('De controleur kon niet geladen worden.');
        }
        return users[0];
    }

    private static Contact loadContact(Id contactId) {
        List<Contact> contacts = [
            SELECT Id, Name, FirstName, LastName, Email
            FROM Contact
            WHERE Id = :contactId
            WITH USER_MODE
            LIMIT 1
        ];
        if (contacts.isEmpty()) {
            throw new DocusignSendException('Het gekozen Contact kon niet geladen worden.');
        }
        return contacts[0];
    }

    private static ContentVersion loadPdf(Id contentVersionId) {
        List<ContentVersion> pdfVersions = [
            SELECT Id, Title, FileExtension, ContentDocumentId, ContentSize
            FROM ContentVersion
            WHERE Id = :contentVersionId
            AND IsLatest = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (pdfVersions.isEmpty()) {
            throw new DocusignSendException('De gekozen PDF bestaat niet meer of is niet de laatste versie. Open het scherm opnieuw.');
        }
        ContentVersion pdf = pdfVersions[0];
        if (pdf.FileExtension == null || pdf.FileExtension.toLowerCase() != 'pdf') {
            throw new DocusignSendException('Het gekozen bestand is geen PDF.');
        }
        if (pdf.ContentSize == null || pdf.ContentSize == 0) {
            throw new DocusignSendException('PDF heeft geen inhoud of ContentSize is 0.');
        }
        return pdf;
    }

    @TestVisible
    private static List<dfsle.Tab> buildCheckboxTabsForContact(Integer maxCheckboxes) {
        List<dfsle.Tab> checkboxTabs = new List<dfsle.Tab>();
        if (maxCheckboxes == null || maxCheckboxes <= 0) {
            return checkboxTabs;
        }

        for (Integer i = 1; i <= maxCheckboxes; i++) {
            String numberPart = String.valueOf(i).leftPad(3, '0');
            String anchor = '\\cb_' + numberPart + '\\';
            // Unieke naam + data label per checkbox, anders koppelt DocuSign ze.
            String checkboxLabel = 'motrac_cb_' + numberPart;

            // Checkboxen zijn optioneel aanwezig -> ignoreIfNotPresent = true.
            dfsle.Tab checkboxTab = new dfsle.CheckboxTab()
                .withName(checkboxLabel)
                .withDataLabel(checkboxLabel)
                .withAnchor(new dfsle.Tab.Anchor(
                    anchor, false, false, 'right', true, true, 'pixels', -9, -4));

            checkboxTabs.add(checkboxTab);
        }
        return checkboxTabs;
    }
}
