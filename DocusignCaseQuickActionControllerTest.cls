@isTest
private class DocusignCaseQuickActionControllerTest {

    /**
     * LET OP: zelfde org-specifieke aandachtspunten als in
     * DocusignEnvelopeServiceTest:
     * 1. Profielnaam 'Standard User' — pas aan als jouw org bv.
     *    'Standaardgebruiker' gebruikt.
     * 2. Verplichte velden op Account/Contact/Case via validation rules.
     * 3. Ter_controle_van__c moet een User-lookup zijn op Case.
     *
     * sendEnvelope() roept onder de motorkap DocusignEnvelopeService aan,
     * waarvan de callout geskipt wordt in test-context. AuraHandledException
     * geeft in tests vaak "Script-thrown exception" terug i.p.v. de echte
     * tekst — we asserteren daarom op het type, niet op de boodschap-inhoud.
     */

    private static User makeControleur(Boolean active, Boolean withEmail) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User u = new User(
            ProfileId = p.Id,
            LastName = 'Controleur',
            Alias = 'ctrl',
            Email = withEmail ? 'controleur_' + unique + '@example.com' : null,
            Username = 'controleur_' + unique + '@example.com.dsleQaTest',
            CommunityNickname = 'qctrl' + unique.right(6),
            TimeZoneSidKey = 'Europe/Amsterdam',
            LocaleSidKey = 'nl_NL',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'nl_NL',
            IsActive = active
        );
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static Id makeCase(Id contactId, Id accountId, Id controleurId) {
        Case c = new Case(
            Subject = 'DocuSign QA test',
            AccountId = accountId,
            ContactId = contactId,
            Ter_controle_van__c = controleurId
        );
        insert c;
        return c.Id;
    }

    private static Id attachFile(Id caseId, String pathOnClient) {
        ContentVersion cv = new ContentVersion(
            Title = pathOnClient.substringBeforeLast('.'),
            PathOnClient = pathOnClient,
            VersionData = Blob.valueOf('FILE-CONTENT-NOT-EMPTY'),
            IsMajorVersion = true
        );
        insert cv;

        Id cdId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = cdId,
            LinkedEntityId = caseId,
            ShareType = 'V'
        );
        return [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :cdId AND IsLatest = true].Id;
    }

    // ---------------------------------------------------------------
    // loadPreview
    // ---------------------------------------------------------------

    @isTest
    static void loadPreview_nullCaseId_addError() {
        Test.startTest();
        DocusignCaseQuickActionController.PreviewResponse response =
            DocusignCaseQuickActionController.loadPreview(null);
        Test.stopTest();

        System.assertEquals(false, response.canSend, 'Geen Case Id mag niet verzendbaar zijn.');
        Boolean caseIdFout = false;
        for (String err : response.errors) {
            if (err.contains('Case Id')) caseIdFout = true;
        }
        System.assert(caseIdFout, 'Verwacht foutmelding over Case Id.');
    }

    @isTest
    static void loadPreview_volledigeCase_canSendTrue() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf');

        Test.startTest();
        DocusignCaseQuickActionController.PreviewResponse response =
            DocusignCaseQuickActionController.loadPreview(caseId);
        Test.stopTest();

        System.assertEquals(true, response.canSend, 'Verwacht canSend=true: ' + String.join(response.errors, '; '));
        System.assertEquals(caseId, response.caseId);
        System.assertEquals(a.Id, response.accountId);
        System.assertEquals(ct.Id, response.contactId);
        System.assertEquals(u.Id, response.controleurId);
        System.assertEquals(1, response.files.size(), 'Verwacht één bestand in de preview.');
        System.assertEquals('pdf', response.files[0].extension.toLowerCase());
    }

    @isTest
    static void loadPreview_geenControleur_canSendFalse() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        Id caseId = makeCase(ct.Id, a.Id, null);
        attachFile(caseId, 'voorstel.pdf');

        Test.startTest();
        DocusignCaseQuickActionController.PreviewResponse response =
            DocusignCaseQuickActionController.loadPreview(caseId);
        Test.stopTest();

        System.assertEquals(false, response.canSend, 'Zonder controleur niet verzendbaar.');
        Boolean controleurFout = false;
        for (String err : response.errors) {
            if (err.contains('Ter controle van')) controleurFout = true;
        }
        System.assert(controleurFout, 'Verwacht foutmelding over controleur.');
    }

    @isTest
    static void loadPreview_filterOpExtensions() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf');
        attachFile(caseId, 'specificatie.docx');
        attachFile(caseId, 'malware.exe'); // niet ondersteund door DocuSign

        Test.startTest();
        DocusignCaseQuickActionController.PreviewResponse response =
            DocusignCaseQuickActionController.loadPreview(caseId);
        Test.stopTest();

        System.assertEquals(true, response.canSend);
        System.assertEquals(2, response.files.size(), 'Exe moet uit de lijst gefilterd zijn.');
        for (DocusignCaseQuickActionController.FileInfo info : response.files) {
            System.assertNotEquals('exe', info.extension.toLowerCase(), 'Exe mag niet in de lijst staan.');
        }
    }

    // ---------------------------------------------------------------
    // sendEnvelope
    // ---------------------------------------------------------------

    @isTest
    static void sendEnvelope_zonderSelectie_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf');

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignCaseQuickActionController.sendEnvelope(caseId, ct.Id, new List<Id>());
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht AuraHandledException bij lege selectie.');
    }

    @isTest
    static void sendEnvelope_zonderPdfInSelectie_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf'); // wel aanwezig, maar NIET geselecteerd
        Id docxId = attachFile(caseId, 'specificatie.docx');

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignCaseQuickActionController.sendEnvelope(caseId, ct.Id, new List<Id>{ docxId });
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht AuraHandledException zonder PDF in selectie.');
    }

    @isTest
    static void sendEnvelope_idNietInPreview_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf');

        // Een Id die niet in de preview-files zit (verwijst naar geen bestaand bestand).
        String prefix = ContentVersion.SObjectType.getDescribe().getKeyPrefix();
        Id phantomId = prefix + '000000000099';

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignCaseQuickActionController.sendEnvelope(caseId, ct.Id, new List<Id>{ phantomId });
        } catch (AuraHandledException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht AuraHandledException als de Id niet in de preview voorkomt.');
    }

    @isTest
    static void sendEnvelope_happyPath() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id pdfId = attachFile(caseId, 'voorstel.pdf');
        Id docxId = attachFile(caseId, 'specificatie.docx');

        Test.startTest();
        String result = DocusignCaseQuickActionController.sendEnvelope(
            caseId, ct.Id, new List<Id>{ pdfId, docxId }
        );
        Test.stopTest();

        System.assert(result != null && result.toLowerCase().contains('verzonden'),
            'Verwacht een succes-boodschap, kreeg: ' + result);
    }
}
