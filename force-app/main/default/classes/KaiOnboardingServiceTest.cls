/**
 * KaiOnboardingServiceTest
 *
 * Test class for KaiOnboardingService covering all 15 scenarios in the
 * SOAP migration test matrix (sdd/kai-soap design).
 *
 * KaiOnboardingService.handlePost(OnboardingRequest) is invoked directly —
 * no RestContext, no JSON serialization. Every assertion runs against the
 * returned OnboardingResponse envelope.
 *
 * Test runner: sf apex run test -n KaiOnboardingServiceTest
 * API Version: 66.0
 *
 * Coverage note — DUPLICATE_RECORD and VALIDATION_RULE_VIOLATION:
 * Unit tests cannot construct a platform DmlException with a controlled
 * getDmlType(0) value. These paths are exercised via the @TestVisible
 * forceDmlStatusCodeOverride flag, which injects the classification that
 * buildDmlErrorResponse() would otherwise read from a real DmlException
 * raised by a Duplicate Rule or Validation Rule in a sandbox org.
 */
@isTest(SeeAllData=false)
private class KaiOnboardingServiceTest {

    // =========================================================================
    // Shared Test Data Constants
    // =========================================================================

    private static final String VALID_ORG_NAME     = 'Acme Dental';
    private static final String VALID_LAST_NAME    = 'Smith';
    private static final String VALID_EMAIL        = 'john.smith@example.com';
    private static final String ROLLBACK_ORG_NAME  = 'RollbackTest';
    private static final String ONBOARD_TYPE_KAI   = 'kai';

    // =========================================================================
    // Test Setup Helpers
    // =========================================================================

    /**
     * Resets all @TestVisible flags on KaiOnboardingService so each test
     * starts from a clean, deterministic state.
     */
    private static void resetFlags() {
        KaiOnboardingService.forceContactFailure        = false;
        KaiOnboardingService.forceDirectDmlInTest        = false;
        KaiOnboardingService.forceDmlStatusCodeOverride  = null;
        KaiOnboardingService.forceGenericException       = false;
        KaiOnboardingService.forceContactGenericException = false;
    }

    /**
     * Builds a fully populated, in-memory OnboardingRequest for direct
     * invocation of KaiOnboardingService.handlePost(req).
     *
     * @param orgName      Value for org_name
     * @param lastName     Value for user.last_name
     * @param email        Value for user.email
     * @param onboardType  Value for onboard_type (pass null to omit)
     * @param orgSfdcId    Value for org_sfdc_id (pass null — triggers Branch A)
     */
    private static KaiOnboardingService.OnboardingRequest buildRequest(
        String orgName,
        String lastName,
        String email,
        String onboardType,
        String orgSfdcId
    ) {
        KaiOnboardingService.OnboardingRequest req = new KaiOnboardingService.OnboardingRequest();
        req.org_id         = '12345';
        req.org_sfdc_id     = orgSfdcId;
        req.onboard_type    = onboardType;
        req.org_name        = orgName;
        req.org_type        = 'Dental Practice';
        req.org_status      = 'Prospect';
        req.license_number  = 'LIC-2026-001';

        KaiOnboardingService.ContactRequest user = new KaiOnboardingService.ContactRequest();
        user.first_name         = 'John';
        user.last_name          = lastName;
        user.email              = email;
        user.phone              = '2145550101';
        user.cell_phone         = '4145550101';
        user.mailing_address_1  = '456 Elm St';
        user.mailing_city       = 'Dallas';
        user.mailing_country    = 'US';
        user.mailing_state      = 'TX';
        user.mailing_zipcode    = '75001';
        user.user_type          = 'Customer Account Owner';
        user.role               = 'Orthodontist';
        user.user_id            = 'USR001';
        user.activation_url     = 'https://portal.example.com/activate/USR001';

        req.user = user;
        return req;
    }

    /**
     * Inserts a pre-existing Account so Branch B (org_sfdc_id present) has a
     * record to look up and update.
     */
    private static Account insertExistingAccount() {
        Account existing = new Account(
            Name              = 'Original Name',
            Type              = 'Other',
            Account_Status__c = 'Prospect',
            RecordTypeId      = Schema.SObjectType.Account
                .getRecordTypeInfosByDeveloperName()
                .get('Commercial')
                .getRecordTypeId()
        );
        insert existing;
        return existing;
    }

    // =========================================================================
    // Scenario 1 — REQ-1: Null request → INVALID_INPUT, zero DML
    // =========================================================================

    /**
     * GIVEN req is null
     * WHEN handlePost(null) is invoked
     * THEN success=false, errorCode=INVALID_INPUT, and no DML is executed
     */
    @isTest
    static void testNullRequestReturnsInvalidInput() {
        resetFlags();

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(null);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false for a null request');
        Assert.areEqual('INVALID_INPUT', resp.errorCode,
            'Expected errorCode INVALID_INPUT for a null request');
        Assert.areEqual('Request body cannot be null', resp.message,
            'Expected the null-guard message');

        List<Account> accounts = [SELECT Id FROM Account];
        Assert.isTrue(accounts.isEmpty(),
            'No Account should be created when the request is null');
    }

    // =========================================================================
    // Scenario 2 — REQ-2: Missing org_name → INVALID_INPUT
    // =========================================================================

    /**
     * GIVEN a request with a null org_name
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=INVALID_INPUT, no DML executed
     */
    @isTest
    static void testMissingOrgName() {
        resetFlags();
        KaiOnboardingService.OnboardingRequest req = buildRequest(null, VALID_LAST_NAME, VALID_EMAIL, null, null);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false for missing org_name');
        Assert.areEqual('INVALID_INPUT', resp.errorCode,
            'Expected errorCode INVALID_INPUT for missing org_name');

        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :VALID_ORG_NAME];
        Assert.isTrue(accounts.isEmpty(),
            'No Account should be created when validation fails');
    }

    // =========================================================================
    // Scenario 3 — REQ-2: Missing user.last_name → INVALID_INPUT
    // =========================================================================

    /**
     * GIVEN a request with a null user.last_name
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=INVALID_INPUT
     *
     * Triangulates Scenario 2 — different field, same validation gate.
     */
    @isTest
    static void testMissingLastName() {
        resetFlags();
        KaiOnboardingService.OnboardingRequest req = buildRequest(VALID_ORG_NAME, null, VALID_EMAIL, null, null);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false for missing last_name');
        Assert.areEqual('INVALID_INPUT', resp.errorCode,
            'Expected errorCode INVALID_INPUT for missing last_name');
    }

    // =========================================================================
    // Scenario 4 — REQ-2: Malformed email → INVALID_INPUT
    // =========================================================================

    /**
     * GIVEN a request with a malformed user.email (no @ symbol)
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=INVALID_INPUT
     *
     * Triangulates validation: third distinct validation rule.
     */
    @isTest
    static void testInvalidEmail() {
        resetFlags();
        KaiOnboardingService.OnboardingRequest req = buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, 'not-an-email', null, null);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false for invalid email');
        Assert.areEqual('INVALID_INPUT', resp.errorCode,
            'Expected errorCode INVALID_INPUT for invalid email');
    }

    // =========================================================================
    // Scenario 5 — Branch A: Success, Kai flag true
    // =========================================================================

    /**
     * GIVEN a valid full request with onboard_type = 'kai'
     * WHEN handlePost is invoked
     * THEN success=true, both Ids populated, Kai_Onboarding__c == true on both records
     */
    @isTest
    static void testSuccessKaiFlagTrue() {
        resetFlags();
        KaiOnboardingService.OnboardingRequest req = buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, ONBOARD_TYPE_KAI, null);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(true, resp.success,
            'Expected success=true for valid payload');
        Assert.areNotEqual(null, resp.accountId,
            'Expected accountId to be populated on success');
        Assert.areNotEqual(null, resp.contactId,
            'Expected contactId to be populated on success');
        Assert.areEqual(ONBOARD_TYPE_KAI, resp.onboard_type,
            'Expected onboard_type to be echoed on success');

        List<Account> accounts = [
            SELECT Id, Name, Kai_Onboarding__c, License_Number__c,
                   Account_Email__c, Account_POC__c, Date_Added_to_Kai__c,
                   ShippingStreet, BillingCity
            FROM Account
            WHERE Id = :resp.accountId
        ];
        Assert.areEqual(1, accounts.size(),
            'Expected exactly 1 Account to be inserted');
        Assert.areEqual(true, accounts[0].Kai_Onboarding__c,
            'Expected Kai_Onboarding__c = true on Account when onboard_type = kai');
        Assert.areEqual('LIC-2026-001', accounts[0].License_Number__c,
            'Expected License_Number__c to be populated from license_number');
        Assert.areEqual(VALID_EMAIL, accounts[0].Account_Email__c,
            'Expected Account_Email__c to be populated from user.email');
        Assert.areEqual(VALID_LAST_NAME, accounts[0].Account_POC__c,
            'Expected Account_POC__c to be populated from user.last_name');
        Assert.areEqual(Date.today(), accounts[0].Date_Added_to_Kai__c,
            'Expected Date_Added_to_Kai__c to be set to today');
        Assert.areEqual('456 Elm St', accounts[0].ShippingStreet,
            'Expected ShippingStreet to be populated from user.mailing_address_1');
        Assert.areEqual('Dallas', accounts[0].BillingCity,
            'Expected BillingCity to be populated from user.mailing_city');

        List<Contact> contacts = [
            SELECT Id, AccountId, Kai_Onboarding__c, Kai_User_ID__c,
                   Kai_Activation_URL__c, Contact_Role__c, Company_User_Type__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        Assert.areEqual(1, contacts.size(),
            'Expected exactly 1 Contact to be inserted');
        Assert.areEqual(true, contacts[0].Kai_Onboarding__c,
            'Expected Kai_Onboarding__c = true on Contact when onboard_type = kai');
        Assert.areEqual(resp.accountId, contacts[0].AccountId,
            'Expected Contact to be linked to the created Account');
        Assert.areEqual('USR001', contacts[0].Kai_User_ID__c,
            'Expected Kai_User_ID__c to be populated from user_id');
        Assert.areEqual('https://portal.example.com/activate/USR001', contacts[0].Kai_Activation_URL__c,
            'Expected Kai_Activation_URL__c to be populated from activation_url');
        Assert.areEqual('Orthodontist', contacts[0].Contact_Role__c,
            'Expected Contact_Role__c to be populated from user.role');
        Assert.areEqual('Account Owner', contacts[0].Company_User_Type__c,
            'Expected Company_User_Type__c to be mapped from Customer Account Owner');
    }

    // =========================================================================
    // Scenario 6 — Branch A: Success, Kai flag false (no onboard_type)
    // =========================================================================

    /**
     * GIVEN a valid request WITHOUT onboard_type
     * WHEN handlePost is invoked
     * THEN success=true, Kai_Onboarding__c == false on both records
     *
     * Triangulates Scenario 5: different onboard_type value → different flag outcome.
     */
    @isTest
    static void testSuccessKaiFlagFalse() {
        resetFlags();
        // null onboardType, null orgSfdcId → Branch A (create new Account)
        KaiOnboardingService.OnboardingRequest req = buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, null);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(true, resp.success,
            'Expected success=true for valid payload');
        Assert.areEqual(null, resp.onboard_type,
            'Expected onboard_type to be echoed as null when absent from the request');

        List<Account> accounts = [
            SELECT Id, Name, Kai_Onboarding__c, License_Number__c
            FROM Account
            WHERE Id = :resp.accountId
        ];
        Assert.areEqual(1, accounts.size(),
            'Expected exactly 1 Account to be inserted');
        Assert.areEqual(false, accounts[0].Kai_Onboarding__c,
            'Expected Kai_Onboarding__c = false on Account when onboard_type is absent');
        Assert.areEqual('LIC-2026-001', accounts[0].License_Number__c,
            'Expected License_Number__c to be populated from license_number');

        List<Contact> contacts = [
            SELECT Id, Kai_Onboarding__c, Kai_User_ID__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        Assert.areEqual(1, contacts.size(),
            'Expected exactly 1 Contact to be inserted');
        Assert.areEqual(false, contacts[0].Kai_Onboarding__c,
            'Expected Kai_Onboarding__c = false on Contact when onboard_type is absent');
        Assert.areEqual('USR001', contacts[0].Kai_User_ID__c,
            'Expected Kai_User_ID__c to be populated from user_id');
    }

    // =========================================================================
    // Scenario 7 — Branch B: org_sfdc_id provided but Account not found
    // =========================================================================

    /**
     * GIVEN a request with org_sfdc_id that does not match any Account in the org
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=ACCOUNT_NOT_FOUND, accountId=null, no DML executed
     */
    @isTest
    static void testOrgSfdcIdNotFound() {
        resetFlags();
        // Valid Salesforce Id format but guaranteed not to exist in test context
        String fakeAccountId = '0016g00000000001AAA';
        KaiOnboardingService.OnboardingRequest req = buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, fakeAccountId);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false when Account not found');
        Assert.areEqual('ACCOUNT_NOT_FOUND', resp.errorCode,
            'Expected errorCode ACCOUNT_NOT_FOUND');
        Assert.areEqual(null, resp.accountId,
            'Expected accountId to be null when Account not found');
        Assert.isTrue(resp.message.contains(fakeAccountId),
            'Expected error message to include the org_sfdc_id that was searched');

        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :VALID_ORG_NAME];
        Assert.isTrue(accounts.isEmpty(),
            'No Account should be created when Branch B cannot find the existing Account');
    }

    // =========================================================================
    // Scenario 8 — Branch B: org_sfdc_id found → Account updated + Contact created
    // =========================================================================

    /**
     * GIVEN a request with a valid org_sfdc_id that matches an existing Account
     * WHEN handlePost is invoked
     * THEN success=true, the existing Account is updated (not a new one created),
     *      and a new Contact is created linked to that Account
     */
    @isTest
    static void testOrgSfdcIdFoundUpdatesAccountAndCreatesContact() {
        resetFlags();
        Account existing = insertExistingAccount();

        KaiOnboardingService.OnboardingRequest req =
            buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, ONBOARD_TYPE_KAI, existing.Id);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(true, resp.success,
            'Expected success=true for Branch B happy path');
        Assert.areEqual(existing.Id, resp.accountId,
            'Expected accountId to be the pre-existing Account, not a newly created one');
        Assert.areNotEqual(null, resp.contactId,
            'Expected contactId to be populated on success');

        List<Account> accounts = [
            SELECT Id, Name, Kai_Onboarding__c, License_Number__c,
                   Account_Email__c, Account_POC__c,
                   ShippingStreet, BillingCity
            FROM Account
            WHERE Id = :existing.Id
        ];
        Assert.areEqual(1, accounts.size(),
            'Expected exactly 1 Account with the pre-existing Id');
        Assert.areEqual(VALID_ORG_NAME, accounts[0].Name,
            'Expected Account Name to be updated to payload org_name');
        Assert.areEqual(true, accounts[0].Kai_Onboarding__c,
            'Expected Kai_Onboarding__c = true on updated Account');
        Assert.areEqual('LIC-2026-001', accounts[0].License_Number__c,
            'Expected License_Number__c to be populated from license_number on Account update');
        Assert.areEqual(VALID_EMAIL, accounts[0].Account_Email__c,
            'Expected Account_Email__c to be populated from user.email on Account update');
        Assert.areEqual(VALID_LAST_NAME, accounts[0].Account_POC__c,
            'Expected Account_POC__c to be populated from user.last_name on Account update');
        Assert.areEqual('456 Elm St', accounts[0].ShippingStreet,
            'Expected ShippingStreet to be populated from user.mailing_address_1 on Account update');
        Assert.areEqual('Dallas', accounts[0].BillingCity,
            'Expected BillingCity to be populated from user.mailing_city on Account update');

        List<Account> allAccounts = [SELECT Id FROM Account];
        Assert.areEqual(1, allAccounts.size(),
            'Branch B must not create a new Account — only the pre-existing one should exist');

        List<Contact> contacts = [
            SELECT Id, AccountId, Kai_Onboarding__c, LastName, Kai_User_ID__c,
                   Kai_Activation_URL__c, Contact_Role__c
            FROM Contact
            WHERE Id = :resp.contactId
        ];
        Assert.areEqual(1, contacts.size(),
            'Expected exactly 1 Contact to be created');
        Assert.areEqual(existing.Id, contacts[0].AccountId,
            'Expected Contact to be linked to the pre-existing Account');
        Assert.areEqual(true, contacts[0].Kai_Onboarding__c,
            'Expected Kai_Onboarding__c = true on Contact');
        Assert.areEqual(VALID_LAST_NAME, contacts[0].LastName,
            'Expected Contact LastName to match payload user.last_name');
        Assert.areEqual('USR001', contacts[0].Kai_User_ID__c,
            'Expected Kai_User_ID__c to be populated from user_id');
        Assert.areEqual('https://portal.example.com/activate/USR001', contacts[0].Kai_Activation_URL__c,
            'Expected Kai_Activation_URL__c to be populated from activation_url');
        Assert.areEqual('Orthodontist', contacts[0].Contact_Role__c,
            'Expected Contact_Role__c to be populated from user.role');
    }

    // =========================================================================
    // Scenario 9 — Branch B: partial merge preserves fields omitted from request
    // =========================================================================

    /**
     * GIVEN an existing Account with values in fields the request below omits
     *       (Phone, ShippingCity) AND a request that omits user.phone/mailing_city
     * WHEN handlePost is invoked
     * THEN fields present in the request are updated, and fields omitted from
     *      the request preserve the Account's existing values
     */
    @IsTest
    static void testOrgSfdcIdFoundPreservesFieldsOmittedFromPayload() {
        resetFlags();
        Account existing = new Account(
            Name              = 'Original Name',
            Type              = 'Other',
            Account_Status__c = 'Prospect',
            Phone             = '9725550199',
            ShippingCity      = 'Original Shipping City',
            RecordTypeId      = Schema.SObjectType.Account
                .getRecordTypeInfosByDeveloperName()
                .get('Commercial')
                .getRecordTypeId()
        );
        insert existing;

        // Request omits user.phone and user.mailing_city (null) — everything else present
        KaiOnboardingService.OnboardingRequest req = new KaiOnboardingService.OnboardingRequest();
        req.org_sfdc_id    = existing.Id;
        req.org_id         = '12345';
        req.org_name       = VALID_ORG_NAME;
        req.org_type       = 'Dental Practice';
        req.org_status     = 'Prospect';
        req.license_number = 'LIC-2026-001';

        KaiOnboardingService.ContactRequest user = new KaiOnboardingService.ContactRequest();
        user.first_name        = 'John';
        user.last_name          = VALID_LAST_NAME;
        user.email              = VALID_EMAIL;
        user.cell_phone         = '4145550101';
        user.mailing_address_1  = '456 Elm St';
        user.mailing_country    = 'US';
        user.mailing_state      = 'TX';
        user.mailing_zipcode    = '75001';
        user.user_type          = 'Customer Account Owner';
        user.role               = 'Orthodontist';
        user.user_id            = 'USR001';
        user.activation_url     = 'https://portal.example.com/activate/USR001';
        req.user = user;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(true, resp.success,
            'Expected success=true for Branch B partial-merge scenario');

        Account updated = [
            SELECT Name, Phone, ShippingCity, ShippingStreet, License_Number__c
            FROM Account
            WHERE Id = :existing.Id
        ];

        // Fields present in the request must be updated
        Assert.areEqual(VALID_ORG_NAME, updated.Name,
            'Expected Name to be updated from request org_name');
        Assert.areEqual('456 Elm St', updated.ShippingStreet,
            'Expected ShippingStreet to be updated from request user.mailing_address_1');
        Assert.areEqual('LIC-2026-001', updated.License_Number__c,
            'Expected License_Number__c to be updated from request license_number');

        // Fields omitted (blank) from the request must preserve the existing Account values
        Assert.areEqual('9725550199', updated.Phone,
            'Expected Phone to be preserved when request does not send user.phone');
        Assert.areEqual('Original Shipping City', updated.ShippingCity,
            'Expected ShippingCity to be preserved when request does not send user.mailing_city');
    }

    // =========================================================================
    // Scenario 10 — Account insert failure → SALESFORCE_DML_ERROR
    // =========================================================================

    /**
     * GIVEN a request that passes validation but causes Account DML failure
     *       (org_name exceeds 255 chars → triggers platform-level field length error)
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=SALESFORCE_DML_ERROR, no Contact created
     *
     * Approach: pass a 256-character org_name. validateInput() only checks for
     * null/empty; the platform enforces the 255-char Name limit at DML time,
     * guaranteeing a deterministic Account DML failure without relying on
     * org-specific validation rules.
     */
    @isTest
    static void testAccountInsertFailure() {
        resetFlags();
        // 256 chars — exceeds Salesforce Account.Name limit of 255
        String longName = 'A'.repeat(256);
        KaiOnboardingService.OnboardingRequest req = buildRequest(longName, VALID_LAST_NAME, VALID_EMAIL, null, null);

        // Activate the @TestVisible flag to force Account DML failure
        KaiOnboardingService.forceDirectDmlInTest = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false when Account DML fails');
        Assert.areEqual('SALESFORCE_DML_ERROR', resp.errorCode,
            'Expected errorCode SALESFORCE_DML_ERROR on Account DML failure');

        // Verify no Contact was created (Account failed first, no AccountId existed)
        List<Contact> contacts = [SELECT Id FROM Contact WHERE LastName = :VALID_LAST_NAME];
        Assert.isTrue(contacts.isEmpty(),
            'No Contact should be created when Account DML fails');
    }

    // =========================================================================
    // Scenario 11 — Contact failure → rollback Account
    // =========================================================================

    /**
     * GIVEN a valid request that passes validation but triggers Contact DML failure
     *       (via @TestVisible forceContactFailure flag)
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=SALESFORCE_DML_ERROR, and zero Accounts
     *      persist in the database (rollback verified via SOQL)
     */
    @isTest
    static void testRollbackOnContactFailure() {
        resetFlags();
        KaiOnboardingService.OnboardingRequest req = buildRequest(ROLLBACK_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, null);

        // Activate the @TestVisible flag to force Contact DML failure
        KaiOnboardingService.forceContactFailure  = true;
        KaiOnboardingService.forceDirectDmlInTest = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false when Contact DML fails');
        Assert.areEqual('SALESFORCE_DML_ERROR', resp.errorCode,
            'Expected errorCode SALESFORCE_DML_ERROR on DML failure');

        // Critical rollback assertion: Account must NOT exist in DB after rollback
        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :ROLLBACK_ORG_NAME];
        Assert.isTrue(accounts.isEmpty(),
            'Account must not persist after Contact DML failure — rollback must have executed');
    }

    // =========================================================================
    // Scenario 12 — Account DML DUPLICATE_VALUE → DUPLICATE_RECORD
    // =========================================================================

    /**
     * GIVEN a DML failure at Account insert whose StatusCode is overridden to
     *       DUPLICATE_VALUE
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=DUPLICATE_RECORD
     *
     * Technique: trigger a real DmlException via a 256-char Account name, then
     * inject the StatusCode via @TestVisible forceDmlStatusCodeOverride so the
     * helper classifies it as a duplicate without relying on org Duplicate Rules.
     */
    @isTest
    static void testDuplicateRecordReturns409() {
        resetFlags();
        String longName = 'A'.repeat(256);
        KaiOnboardingService.OnboardingRequest req = buildRequest(longName, VALID_LAST_NAME, VALID_EMAIL, ONBOARD_TYPE_KAI, null);

        KaiOnboardingService.forceDmlStatusCodeOverride = StatusCode.DUPLICATE_VALUE;
        // Activate the @TestVisible flag to force Account DML failure
        KaiOnboardingService.forceDirectDmlInTest = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false on duplicate error');
        Assert.areEqual('DUPLICATE_RECORD', resp.errorCode,
            'Expected errorCode DUPLICATE_RECORD for DUPLICATE_VALUE StatusCode');
        Assert.isTrue(resp.message.contains('Duplicate record detected'),
            'Expected message to indicate duplicate detection');
    }

    // =========================================================================
    // Scenario 13 — Contact DML DUPLICATE_VALUE → DUPLICATE_RECORD
    // =========================================================================

    /**
     * GIVEN a valid Account (created successfully) but a 256-char user.last_name
     *       forces the Contact insert to throw a DmlException, whose StatusCode
     *       is overridden to DUPLICATE_VALUE
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=DUPLICATE_RECORD
     *
     * This is the sole coverage of the DmlException catch block inside
     * insertContact() — Scenario 12 fails at the Account insert, a different
     * catch block. A 256-char LastName is used (instead of org_name) so the
     * Account insert succeeds and the failure is triggered in the Contact
     * insert path.
     */
    @isTest
    static void testContactDuplicateRecordReturnsDuplicateRecord() {
        resetFlags();
        String longLastName = 'S'.repeat(256);
        KaiOnboardingService.OnboardingRequest req = buildRequest(VALID_ORG_NAME, longLastName, VALID_EMAIL, ONBOARD_TYPE_KAI, null);

        // Override the DML status code so the Contact DmlException is classified as a duplicate
        KaiOnboardingService.forceDmlStatusCodeOverride = StatusCode.DUPLICATE_VALUE;
        // Activate the @TestVisible flag to force Contact DML failure
        KaiOnboardingService.forceDirectDmlInTest = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false on duplicate DML error');
        Assert.areEqual('DUPLICATE_RECORD', resp.errorCode,
            'Expected errorCode DUPLICATE_RECORD for DUPLICATE_VALUE classification');
    }

    // =========================================================================
    // Scenario 14 — VALIDATION_RULE_VIOLATION
    // =========================================================================

    /**
     * GIVEN a DML failure whose StatusCode is overridden to
     *       FIELD_CUSTOM_VALIDATION_EXCEPTION
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=VALIDATION_RULE_VIOLATION
     *
     * Same injection technique as Scenario 12 — real DmlException via 256-char
     * name, StatusCode overridden via @TestVisible flag.
     */
    @isTest
    static void testValidationRuleViolationReturns422() {
        resetFlags();
        String longName = 'A'.repeat(256);
        KaiOnboardingService.OnboardingRequest req = buildRequest(longName, VALID_LAST_NAME, VALID_EMAIL, null, null);

        KaiOnboardingService.forceDmlStatusCodeOverride = StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION;
        // Activate the @TestVisible flag to force DML failure
        KaiOnboardingService.forceDirectDmlInTest = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false on validation rule rejection');
        Assert.areEqual('VALIDATION_RULE_VIOLATION', resp.errorCode,
            'Expected errorCode VALIDATION_RULE_VIOLATION for FIELD_CUSTOM_VALIDATION_EXCEPTION StatusCode');
        Assert.isTrue(resp.message.contains('validation rule rejected'),
            'Expected message to reference validation rule rejection');
    }

    // =========================================================================
    // Scenario 15 — D1 regression: onboard_type echoed on every error path
    // =========================================================================

    /**
     * GIVEN requests that fail at each distinct error stage (validation,
     *       account-not-found, and Account DML failure)
     * WHEN handlePost is invoked with a non-null onboard_type on each
     * THEN the returned envelope's onboard_type equals the request's
     *      onboard_type on every path — regression guard for defect D1,
     *      where buildDmlErrorResponse previously hardcoded 'kai'.
     */
    @isTest
    static void testErrorPathEchoesOnboardType() {
        resetFlags();
        String customOnboardType = 'udesign.cloud';

        // Path 1 — validation failure (INVALID_INPUT)
        KaiOnboardingService.OnboardingRequest validationReq =
            buildRequest(null, VALID_LAST_NAME, VALID_EMAIL, customOnboardType, null);
        KaiOnboardingService.OnboardingResponse validationResp = KaiOnboardingService.handlePost(validationReq);
        Assert.areEqual(customOnboardType, validationResp.onboard_type,
            'Expected onboard_type to be echoed on the INVALID_INPUT path');

        // Path 2 — Account not found (ACCOUNT_NOT_FOUND)
        String fakeAccountId = '0016g00000000001AAA';
        KaiOnboardingService.OnboardingRequest notFoundReq =
            buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, customOnboardType, fakeAccountId);
        KaiOnboardingService.OnboardingResponse notFoundResp = KaiOnboardingService.handlePost(notFoundReq);
        Assert.areEqual(customOnboardType, notFoundResp.onboard_type,
            'Expected onboard_type to be echoed on the ACCOUNT_NOT_FOUND path');

        // Path 3 — Account DML failure (SALESFORCE_DML_ERROR) — regression target for D1
        KaiOnboardingService.forceDirectDmlInTest = true;
        String longName = 'A'.repeat(256);
        KaiOnboardingService.OnboardingRequest dmlReq =
            buildRequest(longName, VALID_LAST_NAME, VALID_EMAIL, customOnboardType, null);

        Test.startTest();
        KaiOnboardingService.OnboardingResponse dmlResp = KaiOnboardingService.handlePost(dmlReq);
        Test.stopTest();

        Assert.areEqual(false, dmlResp.success,
            'Expected success=false on the forced Account DML failure path');
        Assert.areEqual(customOnboardType, dmlResp.onboard_type,
            'D1 regression: onboard_type must be echoed from the request, not hardcoded to "kai"');
    }

    // =========================================================================
    // Scenario 16 — Non-DML exception (trigger/flow) on Account insert → rollback
    // =========================================================================

    /**
     * GIVEN a valid request whose Account insert is intercepted by a
     *       non-DmlException (simulating an uncaught trigger/Flow exception)
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=SALESFORCE_DML_ERROR, and no Contact is created
     */
    @isTest
    static void testAccountInsertGenericExceptionReturnsDmlError() {
        resetFlags();
        KaiOnboardingService.OnboardingRequest req = buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, null);

        KaiOnboardingService.forceGenericException = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false when a non-DML exception is thrown during Account insert');
        Assert.areEqual('SALESFORCE_DML_ERROR', resp.errorCode,
            'Expected errorCode SALESFORCE_DML_ERROR for a non-DML exception on Account insert');

        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :VALID_ORG_NAME];
        Assert.isTrue(accounts.isEmpty(),
            'No Account should persist when Account insert throws a non-DML exception');
        List<Contact> contacts = [SELECT Id FROM Contact WHERE LastName = :VALID_LAST_NAME];
        Assert.isTrue(contacts.isEmpty(),
            'No Contact should be created when Account insert fails');
    }

    // =========================================================================
    // Scenario 17 — Non-DML exception (trigger/flow) on Account update → rollback
    // =========================================================================

    /**
     * GIVEN a pre-existing Account (Branch B) whose update is intercepted by a
     *       non-DmlException
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=SALESFORCE_DML_ERROR, and the pre-existing
     *      Account is rolled back to its original values
     */
    @isTest
    static void testAccountUpdateGenericExceptionRollsBack() {
        resetFlags();
        Account existing = insertExistingAccount();
        KaiOnboardingService.OnboardingRequest req =
            buildRequest(VALID_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, ONBOARD_TYPE_KAI, existing.Id);

        KaiOnboardingService.forceGenericException = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false when a non-DML exception is thrown during Account update');
        Assert.areEqual('SALESFORCE_DML_ERROR', resp.errorCode,
            'Expected errorCode SALESFORCE_DML_ERROR for a non-DML exception on Account update');

        Account unchanged = [SELECT Name FROM Account WHERE Id = :existing.Id];
        Assert.areEqual('Original Name', unchanged.Name,
            'Account must be rolled back to its original values after the non-DML exception');
        List<Contact> contacts = [SELECT Id FROM Contact WHERE LastName = :VALID_LAST_NAME];
        Assert.isTrue(contacts.isEmpty(),
            'No Contact should be created when Account update fails');
    }

    // =========================================================================
    // Scenario 18 — Non-DML exception (trigger/flow) on Contact insert → rollback Account
    // =========================================================================

    /**
     * GIVEN a valid request whose Account insert succeeds but whose Contact
     *       insert is intercepted by a non-DmlException
     * WHEN handlePost is invoked
     * THEN success=false, errorCode=SALESFORCE_DML_ERROR, and the Account is
     *      rolled back (atomicity preserved)
     */
    @isTest
    static void testContactInsertGenericExceptionRollsBackAccount() {
        resetFlags();
        KaiOnboardingService.OnboardingRequest req = buildRequest(ROLLBACK_ORG_NAME, VALID_LAST_NAME, VALID_EMAIL, null, null);

        KaiOnboardingService.forceDirectDmlInTest = true;
        KaiOnboardingService.forceContactGenericException = true;

        Test.startTest();
        KaiOnboardingService.OnboardingResponse resp = KaiOnboardingService.handlePost(req);
        Test.stopTest();

        Assert.areEqual(false, resp.success,
            'Expected success=false when a non-DML exception is thrown during Contact insert');
        Assert.areEqual('SALESFORCE_DML_ERROR', resp.errorCode,
            'Expected errorCode SALESFORCE_DML_ERROR for a non-DML exception on Contact insert');

        List<Account> accounts = [SELECT Id FROM Account WHERE Name = :ROLLBACK_ORG_NAME];
        Assert.isTrue(accounts.isEmpty(),
            'Account must not persist after Contact insert throws a non-DML exception — rollback must have executed');
    }
}
