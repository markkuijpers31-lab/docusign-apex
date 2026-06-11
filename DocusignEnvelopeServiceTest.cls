@isTest
private class DocusignEnvelopeServiceTest {

    /**
     * LET OP - org-specifieke aanpassingen die je mogelijk moet doen:
     * 1. Profielnaam: pas 'Standard User' aan naar jouw org (bv. 'Standaardgebruiker').
     * 2. Verplichte velden: vult jouw org verplichte velden op Account/Contact/Case
     *    in via validation rules of required fields? Voeg die hier toe bij de inserts.
     * 3. Ter_controle_van__c moet een User-lookup zijn op Case.
     *
     * De callout naar DocuSign wordt in de service overgeslagen via
     * Test.isRunningTest(). buildEnvelope() roept wel dfsle-bouwmethodes aan
     * (getEmptyEnvelope, getDocuments). Als jouw DFSLE-package custom settings
     * vereist die in een lege testcontext ontbreken, kan de happy-path test
     * falen op die dfsle-call. De negatieve paden raken dfsle nooit en zijn
     * dus altijd betrouwbaar.
     */

    private static User makeControleur(Boolean active, Boolean withEmail) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User u = new User(
            ProfileId = p.Id,
            LastName = 'Controleur',
            Alias = 'ctrl',
            Email = withEmail ? 'controleur_' + unique + '@example.com' : null,
            Username = 'controleur_' + unique + '@example.com.dsleTest',
            CommunityNickname = 'ctrl' + unique.right(6),
            TimeZoneSidKey = 'Europe/Amsterdam',
            LocaleSidKey = 'nl_NL',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'nl_NL',
            IsActive = active
        );
        insert u;
        return u;
    }

    private static Id makeCase(Id contactId, Id accountId, Id controleurId) {
        Case c = new Case(
            Subject = 'DocuSign test',
            AccountId = accountId,
            ContactId = contactId,
            Ter_controle_van__c = controleurId
        );
        insert c;
        return c.Id;
    }

    private static Id attachPdf(Id caseId, String pathOnClient) {
        ContentVersion cv = new ContentVersion(
            Title = 'TestVoorstel',
            PathOnClient = pathOnClient,            // 'test.pdf' -> FileExtension 'pdf'
            VersionData = Blob.valueOf('PDF-CONTENT-NOT-EMPTY'),
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
    // Negatieve paden - raken dfsle NIET, altijd betrouwbaar
    // ---------------------------------------------------------------

    @isTest
    static void buildEnvelope_nullCase_throws() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(null, null, null);
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht DocusignSendException bij null caseId.');
    }

    @isTest
    static void buildEnvelope_geenControleur_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;

        Id caseId = makeCase(ct.Id, a.Id, null); // geen controleur
        Id cvId = attachPdf(caseId, 'test.pdf');

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, cvId);
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Ter controle van'), 'Verwacht melding over controleur.');
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij ontbrekende controleur.');
    }

    @isTest
    static void buildEnvelope_inactieveControleur_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(false, true); // inactief

        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id cvId = attachPdf(caseId, 'test.pdf');

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, cvId);
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij inactieve controleur.');
    }

    @isTest
    static void buildEnvelope_geenPdf_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        // geen PDF gekoppeld; geef een nep-Id mee dat niet bestaat
        Id fakeCvId = ContentVersion.SObjectType.getDescribe().getKeyPrefix() + '000000000000AAA';

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, fakeCvId);
        } catch (Exception e) {
            thrown = true; // DocusignSendException of QueryException
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij niet-bestaande PDF.');
    }

    @isTest
    static void checkboxTabs_buildsExpectedCount() {
        Test.startTest();
        List<dfsle.Tab> tabs10 = DocusignEnvelopeService.buildCheckboxTabsForContact(10);
        List<dfsle.Tab> tabs0  = DocusignEnvelopeService.buildCheckboxTabsForContact(0);
        Test.stopTest();
        System.assertEquals(10, tabs10.size(), 'Verwacht 10 checkbox-tabs.');
        System.assertEquals(0,  tabs0.size(),  'Verwacht 0 tabs bij 0.');
    }

    // ---------------------------------------------------------------
    // Controller-pad - valideert errors + optimistic lock (geen dfsle)
    // ---------------------------------------------------------------

    @isTest
    static void controller_geenPdf_zetError() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id); // geen PDF

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Case(Id = caseId));
        DocusignCaseConfirmController ctrl = new DocusignCaseConfirmController(sc);
        Test.stopTest();

        System.assert(ctrl.getHasErrors(), 'Verwacht errors zonder PDF.');
        System.assert(ctrl.getDisableSend(), 'Knop moet disabled zijn.');
    }

    // ---------------------------------------------------------------
    // Happy path - raakt dfsle. Zie LET OP bovenaan als dit faalt.
    // ---------------------------------------------------------------

    @isTest
    static void buildEnvelope_happyPath() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id cvId = attachPdf(caseId, 'test.pdf');

        Test.startTest();
        // Via de publieke entry point; callout wordt geskipt door Test.isRunningTest().
        DocusignEnvelopeService.sendLatestPdfFromCase(caseId, ct.Id, cvId);
        Test.stopTest();
        // Geen exception = pad doorlopen. Assertions op de envelope kun je toevoegen
        // door buildEnvelope() direct aan te roepen en recipients te inspecteren.
    }
}
