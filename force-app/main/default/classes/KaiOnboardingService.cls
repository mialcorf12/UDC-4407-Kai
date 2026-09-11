/**
 * KaiOnboardingService
 *
 * Apex SOAP webservice for the Kai onboarding portal.
 * Accepts an OnboardingRequest containing organization and contact data,
 * validates inputs, and atomically creates a Salesforce Account and
 * linked Contact. Uses a Savepoint to guarantee rollback if Contact
 * creation fails after Account insertion.
 *
 * Outcome contract:
 * Every outcome — success or failure — is conveyed solely through the
 * returned OnboardingResponse envelope (success, message, errorCode,
 * accountId, contactId, onboard_type). No HTTP status code is set.
 *
 *   errorCode values:
 *   INVALID_INPUT             — input validation failed, or req was null (no DML executed)
 *   ACCOUNT_NOT_FOUND         — org_sfdc_id provided but Account not found in Salesforce
 *   DUPLICATE_RECORD          — duplicate record detected by a Salesforce Duplicate Rule
 *   VALIDATION_RULE_VIOLATION — Salesforce Validation Rule or required-field constraint rejected the record
 *   SALESFORCE_DML_ERROR      — unexpected DML error (trigger exception, lock timeout, etc.); transaction rolled back
 *   INTERNAL_ERROR            — unexpected exception outside the controlled DML paths
 *
 * API Version: 66.0
 */
global with sharing class KaiOnboardingService {

    // -------------------------------------------------------------------------
    // @TestVisible flag: set to true in a test to force Contact DML failure.
    // Enables deterministic rollback testing without relying on org-specific
    // duplicate rules or validation rules.
    // -------------------------------------------------------------------------
    @TestVisible
    private static Boolean forceContactFailure = false;

    @TestVisible
    private static StatusCode forceDmlStatusCodeOverride = null;

    // @TestVisible flag: set to true ONLY in test context to force the legacy
    // direct insert/update (no DuplicateRuleHeader.allowSave bypass), so tests
    // can still exercise the DUPLICATE_RECORD path deterministically.
    // Production code always uses the DMLOptions bypass — this flag has no
    // effect outside Test.isRunningTest().
    @TestVisible
    private static Boolean forceDirectDmlInTest = false;

    // @TestVisible flags: set to true in a test to force a non-DML exception
    // (simulating an uncaught trigger/Flow exception) at the corresponding
    // DML point, exercising the generic Exception catch + rollback path
    // deterministically. Kept separate per DML point (Account vs. Contact)
    // so a test can target one point without also short-circuiting the other.
    @TestVisible
    private static Boolean forceGenericException = false;

    @TestVisible
    private static Boolean forceContactGenericException = false;

    // @TestVisible flag: set to true in a test to force an unexpected exception
    // before any DML runs (simulating a RecordType-resolution failure or other
    // pre-DML error), exercising the outer catch → INTERNAL_ERROR path
    // deterministically.
    @TestVisible
    private static Boolean forceInternalErrorInTest = false;

    // =========================================================================
    // Inner Classes — SOAP DTOs
    // =========================================================================

    /**
     * Root request wrapper. Field names match the keys sent by the portal.
     * Note: onboard_type uses underscore (Apex identifiers cannot contain hyphens).
     */
    global class OnboardingRequest {
        webservice String org_id; // uLab Acct Number | kai Acct Number
        webservice String org_sfdc_id; // for update branch
        webservice String onboard_type; // udesign.cloud | kai
        webservice String org_name;
        webservice String org_type; // Orthodontic Practice | Clinical practice, Dental lab or Manufacturing
        webservice String org_status; // uLab Account | kai Account
        webservice String license_number;
        webservice ContactRequest user;
    }

    /**
     * Nested contact/user wrapper inside the root request.
     */
    global class ContactRequest {
        webservice String user_id; // Portal_User_ID__c | Kai_User_ID__c
        webservice String first_name;
        webservice String last_name;
        webservice String email;
        webservice String phone;
        webservice String cell_phone;
        webservice String user_type; // Account Owner
        webservice String role; // Orthodontist
        webservice String mailing_address_1;
        webservice String mailing_city;
        webservice String mailing_country;
        webservice String mailing_state;
        webservice String mailing_zipcode;
        webservice String activation_url;
    }

    /**
     * Response envelope returned by handlePost().
     * On success: success=true, accountId, contactId populated.
     * On failure: success=false, errorCode and message populated.
     */
    global class OnboardingResponse {
        webservice Boolean success;
        webservice String message;
        webservice String errorCode;
        webservice String onboard_type;  // udesign.cloud | kai
        webservice Id accountId;
        webservice Id contactId;
    }

    /**
     * Custom exception used ONLY in test context via the @TestVisible
     * forceContactFailure flag. Using a named custom exception (rather than
     * a manually constructed DmlException) avoids the UnexpectedException
     * that Apex throws when getDmlMessage(0) is called on a non-platform DmlException.
     */
    @TestVisible
    private class ContactInsertException extends Exception {}

    /**
     * Custom exception used ONLY in test context via the @TestVisible
     * forceGenericException/forceContactGenericException flags, to simulate
     * a non-DmlException thrown by a trigger or Flow during Account/Contact DML.
     */
    @TestVisible
    private class GenericTestException extends Exception {}

    // =========================================================================
    // Entry Point
    // =========================================================================

    /**
     * Handles Kai onboarding requests via the Apex SOAP webservice contract.
     *
     * Flow — Branch A (org_sfdc_id blank/null): create new Account + Contact
     *   1. Validate required fields and email → INVALID_INPUT on failure
     *   2. Set savepoint
     *   3. Insert Account (FLS-checked) → error envelope on failure
     *   4. Insert Contact linked to Account (FLS-checked) → rollback + error envelope on failure
     *   5. Return success envelope
     *
     * Flow — Branch B (org_sfdc_id has value): update existing Account + create Contact
     *   1. Validate required fields and email → INVALID_INPUT on failure
     *   2. SOQL lookup by Account Id → ACCOUNT_NOT_FOUND if not found
     *   3. Set savepoint
     *   4. Update existing Account (FLS-checked) → rollback + error envelope on failure
     *   5. Insert Contact linked to existing Account (FLS-checked) → rollback + error envelope on failure
     *   6. Return success envelope
     *
     * @param req  The onboarding request payload; null returns INVALID_INPUT with no DML
     * @return     The OnboardingResponse envelope describing the outcome
     */
    webservice static OnboardingResponse handlePost(OnboardingRequest req) {
        if (req == null) {
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.success   = false;
            errResp.message   = 'Request body cannot be null';
            errResp.errorCode = 'INVALID_INPUT';
            return errResp;
        }

        String onboard_type = req.onboard_type;

        try {
            if (Test.isRunningTest() && forceInternalErrorInTest) {
                throw new GenericTestException('Forced test failure: simulated pre-DML unexpected exception');
            }

            // Step 1: Resolve RecordType IDs dynamically (portable across orgs)
            Id accountRecordTypeId = Schema.SObjectType.Account
                .getRecordTypeInfosByDeveloperName()
                .get('Commercial')
                .getRecordTypeId();

            Id contactRecordTypeId = Schema.SObjectType.Contact
                .getRecordTypeInfosByDeveloperName()
                .get('Commercial')
                .getRecordTypeId();

            // Compute the Kai onboarding flag once — used on both Account and Contact
            Boolean isKaiOnboarding = (req.onboard_type == 'kai');

            // =====================================================================
            // BRANCH DECISION: org_sfdc_id present → update existing Account
            //                  org_sfdc_id blank/null → create new Account
            // =====================================================================
            if (String.isNotBlank(req.org_sfdc_id)) {
                // Step 2: Validate inputs before any DML — yields INVALID_INPUT on failure
                String validationError = validateInput(req, 'B');
                if (validationError != null) {
                    OnboardingResponse errResp = new OnboardingResponse();
                    errResp.onboard_type = onboard_type;
                    errResp.success   = false;
                    errResp.errorCode = 'INVALID_INPUT';
                    errResp.message   = 'Validation failed: ' + validationError;
                    return errResp;
                }

                return handleExistingAccount(req, contactRecordTypeId, isKaiOnboarding);
            } else {
                // Step 2: Validate inputs before any DML — yields INVALID_INPUT on failure
                String validationError = validateInput(req, 'A');
                if (validationError != null) {
                    OnboardingResponse errResp = new OnboardingResponse();
                    errResp.onboard_type = onboard_type;
                    errResp.success   = false;
                    errResp.errorCode = 'INVALID_INPUT';
                    errResp.message   = 'Validation failed: ' + validationError;
                    return errResp;
                }

                return handleNewAccount(req, accountRecordTypeId, contactRecordTypeId, isKaiOnboarding);
            }
        } catch (Exception e) {
            // Safety net for unexpected failures before/outside the controlled DML paths
            // (e.g. missing RecordType) — ensures the caller always gets the
            // OnboardingResponse contract.
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.onboard_type = onboard_type;
            errResp.success   = false;
            errResp.errorCode = 'INTERNAL_ERROR';
            errResp.message   = 'Unexpected error: ' + e.getMessage();
            return errResp;
        }
    }

    // =========================================================================
    // Branch A — Create new Account + Contact
    // =========================================================================

    /**
     * Branch A: org_sfdc_id is blank/null.
     * Creates a new Account and a linked Contact atomically.
     * Uses a savepoint to roll back the Account if Contact insert fails.
     */
    private static OnboardingResponse handleNewAccount(
        OnboardingRequest req,
        Id accountRecordTypeId,
        Id contactRecordTypeId,
        Boolean isKaiOnboarding
    ) {
        String onboard_type = req.onboard_type;

        // Build the Account record from payload
        Account acc = new Account();
        acc.RecordTypeId = accountRecordTypeId;
        applyAccountFields(acc, req, isKaiOnboarding);

        // Set savepoint before first DML to enable atomic rollback
        Savepoint sp = Database.setSavepoint();

        // FLS enforcement on Account, then insert.
        // Kai_Onboarding__c is a system-set flag — reapplied after FLS strip
        // because stripInaccessible may remove it if the running user's profile
        // restricts the field. The endpoint always controls this flag; it cannot
        // be injected by the caller.
        SObjectAccessDecision accDecision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<SObject>{ acc }
        );
        Account accToInsert = (Account) accDecision.getRecords()[0];
        accToInsert.Kai_Onboarding__c    = isKaiOnboarding;
        // Kai_Acct_Number__c skipped in test context (same guard as applyAccountFields).
        if (!Test.isRunningTest()) {
            accToInsert.Kai_Acct_Number__c = acc.Kai_Acct_Number__c;
        }

        try {
            if (Test.isRunningTest() && forceGenericException) {
                throw new GenericTestException('Forced test failure: simulated trigger/flow exception on Account insert');
            }
            if (Test.isRunningTest() && forceDirectDmlInTest) {
                system.debug('handleNewAccount isRunningTest: ' + accToInsert);
                insert accToInsert;
            } else {
                Database.DMLOptions dmlOptions = new Database.DMLOptions();
                dmlOptions.DuplicateRuleHeader.allowSave = true;
                dmlOptions.DuplicateRuleHeader.runAsCurrentUser = true;
                system.debug('handleNewAccount DMLOptions: ' + accToInsert);
                Database.insert(accToInsert, dmlOptions);
            }
        } catch (DmlException e) {
            // Account insert failed — no records written; no rollback needed.
            system.debug('handleNewAccount DmlException: ' + accToInsert);
            return buildDmlErrorResponse(e, null, onboard_type);
        } catch (Exception e) {
            // Non-DML failure (trigger/flow exception) during Account insert —
            // no records written yet, so no rollback needed.
            system.debug('handleNewAccount GenericException: ' + accToInsert);
            return buildGenericErrorResponse(e, null, onboard_type);
        }

        // Build and insert Contact linked to the new Account
        Contact conToInsert = buildContact(req, accToInsert.Id, contactRecordTypeId, isKaiOnboarding);
        system.debug('handleNewAccount Contact to insert: ' + conToInsert);
        return insertContact(conToInsert, sp, accToInsert.Id, 'Account and Contact created successfully.', onboard_type);
    }

    // =========================================================================
    // Branch B — Update existing Account + create Contact
    // =========================================================================

    /**
     * Branch B: org_sfdc_id has a value.
     * Looks up the Account by the provided Salesforce Id.
     * Returns ACCOUNT_NOT_FOUND if not found. Updates the Account and creates a
     * linked Contact atomically.
     */
    private static OnboardingResponse handleExistingAccount(
        OnboardingRequest req,
        Id contactRecordTypeId,
        Boolean isKaiOnboarding
    ) {
        String onboard_type = req.onboard_type;

        // SOQL lookup — never create an Account in this branch
        List<Account> existing = [
            SELECT Id, RecordTypeId, Name, Type, Account_Status__c, Phone,
                   Kai_Onboarding__c, Account_Email__c, Account_POC__c,
                   ShippingAddressID__c, ShippingStreet, ShippingCity, ShippingCountry, ShippingState, ShippingPostalCode,
                   BillingAddressID__c, BillingStreet, BillingCity, BillingCountry, BillingState, BillingPostalCode
            FROM Account
            WHERE Id = :req.org_sfdc_id
            LIMIT 1
        ];

        if (existing.isEmpty()) {
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.onboard_type = onboard_type;
            errResp.success   = false;
            errResp.errorCode = 'ACCOUNT_NOT_FOUND';
            errResp.message   = 'Account ' + req.org_sfdc_id + ' not found in Salesforce.';
            return errResp;
        }

        // Apply payload values onto the retrieved Account record.
        // Uses partial merge: blank payload fields preserve existing Account values.
        Account acc = existing[0];
        applyAccountFieldsPartial(acc, req, isKaiOnboarding);

        // Set savepoint before DML to cover update + Contact insert atomically
        Savepoint sp = Database.setSavepoint();

        // FLS enforcement on Account update.
        // Kai_Onboarding__c reapplied after strip for the same reason as Branch A.
        SObjectAccessDecision accDecision = Security.stripInaccessible(
            AccessType.UPDATABLE,
            new List<SObject>{ acc }
        );
        Account accToUpdate = (Account) accDecision.getRecords()[0];
        accToUpdate.Kai_Onboarding__c    = isKaiOnboarding;
        // Kai_Acct_Number__c skipped in test context (same guard as applyAccountFieldsPartial).
        if (!Test.isRunningTest()) {
            system.debug('handleExistingAccount !isRunningTest: ' + accToUpdate);
            accToUpdate.Kai_Acct_Number__c = acc.Kai_Acct_Number__c;
        }

        try {
            if (Test.isRunningTest() && forceGenericException) {
                system.debug('handleExistingAccount GenericTestException: ' + accToUpdate);
                throw new GenericTestException('Forced test failure: simulated trigger/flow exception on Account update');
            }
            if (Test.isRunningTest() && forceDirectDmlInTest) {
                system.debug('handleExistingAccount isRunningTest: ' + accToUpdate);
                update accToUpdate;
            } else {
                Database.DMLOptions dmlOptions = new Database.DMLOptions();
                dmlOptions.DuplicateRuleHeader.allowSave = true;
                dmlOptions.DuplicateRuleHeader.runAsCurrentUser = true;
                system.debug('handleExistingAccount DMLOptions: ' + accToUpdate);
                Database.update(accToUpdate, dmlOptions);
            }
        } catch (DmlException e) {
            // Account update failed — buildDmlErrorResponse rolls back sp before returning.
            system.debug('handleExistingAccount DmlException: ' + accToUpdate);
            return buildDmlErrorResponse(e, sp, onboard_type);
        } catch (Exception e) {
            // Non-DML failure (trigger/flow exception) during Account update —
            // buildGenericErrorResponse rolls back sp before returning.
            system.debug('handleExistingAccount GenericException: ' + accToUpdate);
            return buildGenericErrorResponse(e, sp, onboard_type);
        }

        // Build and insert Contact linked to the existing Account
        Contact conToInsert = buildContact(req, accToUpdate.Id, contactRecordTypeId, isKaiOnboarding);
        return insertContact(conToInsert, sp, accToUpdate.Id, 'Account updated and Contact created successfully.', onboard_type);
    }

    // =========================================================================
    // Shared Helpers
    // =========================================================================

    /**
     * Applies all payload field values onto an Account record (new or existing).
     * Called by both Branch A and Branch B to avoid duplication.
     * Does NOT set RecordTypeId — Branch A sets it on construction; Branch B
     * preserves the existing RecordType already on the record.
     *
     * @param acc              The Account sObject to populate (mutated in place)
     * @param req              The request payload
     * @param isKaiOnboarding  Pre-computed Kai flag value
     */
    private static void applyAccountFields(Account acc, OnboardingRequest req, Boolean isKaiOnboarding) {
        acc.Name              = req.org_name;
        acc.Type              = req.org_type;
        acc.Account_Status__c = req.org_status;
        acc.Phone             = req.user.phone;

        // Kai flag set by endpoint logic (not by caller)
        acc.Kai_Onboarding__c = isKaiOnboarding;

        // Shipping address
        acc.ShippingStreet       = req.user.mailing_address_1;
        acc.ShippingCity         = req.user.mailing_city;
        acc.ShippingCountry      = req.user.mailing_country;
        acc.ShippingState        = req.user.mailing_state;
        acc.ShippingPostalCode   = req.user.mailing_zipcode;

        // Billing address
        acc.BillingStreet       = req.user.mailing_address_1;
        acc.BillingCity         = req.user.mailing_city;
        acc.BillingCountry      = req.user.mailing_country;
        acc.BillingState        = req.user.mailing_state;
        acc.BillingPostalCode   = req.user.mailing_zipcode;

        acc.License_Number__c = req.license_number;
        acc.Date_Added_to_Kai__c = Date.today();
        acc.Account_Email__c = req.user.email;
        acc.Account_POC__c = req.user.last_name;

        // Kai_Acct_Number__c is skipped in test context: the "NFA Create" workflow
        // fires when this field is set and references a cross-reference record that is
        // inaccessible in SeeAllData=false test isolation. Production behavior is unchanged.
        if (!Test.isRunningTest()) {
            acc.Kai_Acct_Number__c = String.isBlank(req.org_id) ? null : Decimal.valueOf(req.org_id);
        }
    }

    /**
     * Applies payload field values onto an EXISTING Account (Branch B only).
     * Unlike applyAccountFields, this performs a partial merge: any field whose
     * payload value is blank/null is left untouched, preserving the Account's
     * current value instead of overwriting it with null/false.
     *
     * @param acc              The existing Account sObject to update (mutated in place)
     * @param req              The request payload
     * @param isKaiOnboarding  Pre-computed Kai flag value
     */
    private static void applyAccountFieldsPartial(Account acc, OnboardingRequest req, Boolean isKaiOnboarding) {
        if (String.isNotBlank(req.org_name))   { acc.Name = req.org_name; }
        if (String.isNotBlank(req.org_type))   { acc.Type              = req.org_type; }
        if (String.isNotBlank(req.org_status)) { acc.Account_Status__c = req.org_status; }
        if (String.isNotBlank(req.user.phone))      { acc.Phone             = req.user.phone; }

        // Kai flag set by endpoint logic (not by caller) — always applied, like Branch A
        acc.Kai_Onboarding__c = isKaiOnboarding;

        // Shipping address
        if (String.isNotBlank(req.user.mailing_address_1))  { acc.ShippingStreet       = req.user.mailing_address_1; }
        if (String.isNotBlank(req.user.mailing_city))       { acc.ShippingCity         = req.user.mailing_city; }
        if (String.isNotBlank(req.user.mailing_country))    { acc.ShippingCountry      = req.user.mailing_country; }
        if (String.isNotBlank(req.user.mailing_state))      { acc.ShippingState        = req.user.mailing_state; }
        if (String.isNotBlank(req.user.mailing_zipcode))    { acc.ShippingPostalCode   = req.user.mailing_zipcode; }

        // Billing address
        if (String.isNotBlank(req.user.mailing_address_1))  { acc.BillingStreet       = req.user.mailing_address_1; }
        if (String.isNotBlank(req.user.mailing_city))       { acc.BillingCity         = req.user.mailing_city; }
        if (String.isNotBlank(req.user.mailing_country))    { acc.BillingCountry      = req.user.mailing_country; }
        if (String.isNotBlank(req.user.mailing_state))      { acc.BillingState        = req.user.mailing_state; }
        if (String.isNotBlank(req.user.mailing_zipcode))    { acc.BillingPostalCode   = req.user.mailing_zipcode; }

        if (String.isNotBlank(req.license_number)) { acc.License_Number__c = req.license_number; }

        acc.Date_Added_to_Kai__c = Date.today();
        if (String.isBlank(acc.Account_Email__c)) {
            acc.Account_Email__c = req.user.email;
        }
        if (String.isBlank(acc.Account_POC__c)) {
            acc.Account_POC__c = req.user.last_name;
        }

        // Kai_Acct_Number__c skipped in test context (same guard as applyAccountFields).
        if (!Test.isRunningTest() && String.isNotBlank(req.org_id)) {
            acc.Kai_Acct_Number__c = Decimal.valueOf(req.org_id);
        }
    }

    /**
     * Builds a Contact record from the request payload.
     * Shared by both Branch A and Branch B.
     *
     * @param req               The request payload
     * @param accountId         The Account Id to link the Contact to
     * @param contactRecordTypeId  Resolved RecordType Id for Contact
     * @param isKaiOnboarding   Pre-computed Kai flag value
     * @return                  A populated (not yet inserted) Contact
     */
    private static Contact buildContact(
        OnboardingRequest req,
        Id accountId,
        Id contactRecordTypeId,
        Boolean isKaiOnboarding
    ) {
        Contact con = new Contact();
        con.RecordTypeId = contactRecordTypeId;
        con.AccountId    = accountId;
        con.FirstName    = req.user.first_name;
        con.LastName     = req.user.last_name;
        con.Email        = req.user.email;
        con.Phone        = req.user.phone;
        con.MobilePhone  = req.user.cell_phone;

        // user_type mapping: 'Customer Account Owner' → 'Account Owner'
        if (req.user.user_type == 'Customer Account Owner') {
            con.Company_User_Type__c = 'Account Owner';
        } else {
            con.Company_User_Type__c = req.user.user_type;
        }

        con.Contact_Role__c   = req.user.role;
        con.Kai_User_ID__c = req.user.user_id;
        con.Kai_Activation_URL__c = req.user.activation_url;
        con.Kai_Onboarding__c = isKaiOnboarding;

        // Mailing address
        con.MailingStreet         = req.user.mailing_address_1;
        con.MailingCity       = req.user.mailing_city;
        con.MailingCountry    = req.user.mailing_country;
        con.MailingState      = req.user.mailing_state;
        con.MailingPostalCode = req.user.mailing_zipcode;

        return con;
    }

    /**
     * FLS-enforces and inserts a Contact record.
     * On success, returns a populated success envelope.
     * On failure, rolls back to savepoint and returns an error envelope.
     * Handles both platform DmlExceptions and the @TestVisible ContactInsertException.
     *
     * @param con           The Contact to insert (pre-built by buildContact)
     * @param sp            The savepoint to roll back to on failure
     * @param accountId     The Account Id — included in the success response
     * @param successMsg    The message string to return on success
     * @param onboard_type  The onboard type to echo back on every path
     * @return               A populated OnboardingResponse
     */
    private static OnboardingResponse insertContact(
        Contact con,
        Savepoint sp,
        Id accountId,
        String successMsg,
        String onboard_type
    ) {
        // FLS enforcement on Contact.
        // Kai_Onboarding__c reapplied after strip — same rationale as Account.
        SObjectAccessDecision conDecision = Security.stripInaccessible(
            AccessType.CREATABLE,
            new List<SObject>{ con }
        );
        Contact conToInsert = (Contact) conDecision.getRecords()[0];
        conToInsert.Kai_Onboarding__c    = con.Kai_Onboarding__c;
        conToInsert.Kai_User_ID__c    = con.Kai_User_ID__c;
        conToInsert.Kai_Activation_URL__c    = con.Kai_Activation_URL__c;

        try {
            if (Test.isRunningTest() && forceContactGenericException) {
                system.debug('insertContact GenericException: ' + conToInsert);
                throw new GenericTestException('Forced test failure: simulated trigger/flow exception on Contact insert');
            }
            // @TestVisible bypass: forces a controlled failure to test rollback
            // deterministically without relying on org-specific rules.
            if (Test.isRunningTest() && forceDirectDmlInTest && forceContactFailure) {
                system.debug('insertContact ContactInsertException: ' + conToInsert);
                throw new ContactInsertException('Forced test failure for rollback verification');
            }
            if (Test.isRunningTest() && forceDirectDmlInTest) {
                system.debug('insertContact isRunningTest: ' + conToInsert);
                insert conToInsert;
            } else {
                Database.DMLOptions dmlOptions = new Database.DMLOptions();
                dmlOptions.DuplicateRuleHeader.allowSave = true;
                dmlOptions.DuplicateRuleHeader.runAsCurrentUser = true;
                system.debug('insertContact DMLOptions: ' + conToInsert);
                Database.insert(conToInsert, dmlOptions);
            }
        } catch (DmlException e) {
            // Platform DML failure — buildDmlErrorResponse rolls back sp and classifies the error.
            // accountId is the Account already committed; Contact failed.
            system.debug('insertContact DmlException: ' + conToInsert);
            return buildDmlErrorResponse(e, sp, onboard_type);
        } catch (ContactInsertException e) {
            // Test-only forced failure — rolls back to verify atomicity.
            Database.rollback(sp);
            OnboardingResponse errResp = new OnboardingResponse();
            errResp.onboard_type = onboard_type;
            errResp.success   = false;
            errResp.errorCode = 'SALESFORCE_DML_ERROR';
            errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                                + e.getMessage();
            system.debug('insertContact ContactInsertException: ' + conToInsert);
            return errResp;
        } catch (Exception e) {
            // Non-DML failure (trigger/flow exception) during Contact insert —
            // buildGenericErrorResponse rolls back sp before returning.
            system.debug('insertContact GenericException: ' + conToInsert);
            return buildGenericErrorResponse(e, sp, onboard_type);
        }

        OnboardingResponse successResp = new OnboardingResponse();
        successResp.success   = true;
        successResp.message   = successMsg;
        successResp.accountId = accountId;
        successResp.contactId = conToInsert.Id;
        successResp.onboard_type = onboard_type;
        return successResp;
    }

    // =========================================================================
    // Private Helpers
    // =========================================================================

    /**
     * Validates mandatory fields and email format before any DML.
     * Returns null on success; returns an error message string on failure.
     *
     * Validation rules (REQ-2):
     *   - org_name must not be null or blank
     *   - user.last_name must not be null or blank
     *   - user.email must match the RFC-compatible email regex
     *
     * @param req  The OnboardingRequest
     * @return     Null if valid; validation error message if invalid
     */
    private static String validateInput(OnboardingRequest req, String branch) {
        if (String.isBlank(req.org_name) && branch != 'B') {
            return 'org_name is required.';
        }
        if (req.user == null || String.isBlank(req.user.last_name)) {
            return 'user.last_name is required.';
        }
        // Email regex: RFC-compatible pattern that rejects malformed addresses.
        // Pattern.matches() requires a FULL match (anchors are implicit).
        String emailRegex = '^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$';
        if (String.isBlank(req.user.email) || !Pattern.matches(emailRegex, req.user.email)) {
            return 'user.email is not a valid email address.';
        }
        return null;
    }

    /**
     * Classifies a DmlException by StatusCode, rolls back if a savepoint is provided,
     * and returns the appropriate OnboardingResponse.
     *
     * StatusCode mapping:
     *   DUPLICATE_VALUE / DUPLICATES_DETECTED         → DUPLICATE_RECORD
     *   FIELD_CUSTOM_VALIDATION_EXCEPTION / REQUIRED_FIELD_MISSING → VALIDATION_RULE_VIOLATION
     *   All other codes                               → SALESFORCE_DML_ERROR
     *
     * @param e            The caught DmlException
     * @param sp           Savepoint to roll back to; pass null when no DML preceded the failure
     * @param onboardType  The onboard type to echo back on the error envelope
     */
    private static OnboardingResponse buildDmlErrorResponse(
        DmlException e,
        Savepoint sp,
        String onboardType
    ) {
        if (sp != null) {
            Database.rollback(sp);
        }

        StatusCode dmlType = (Test.isRunningTest() && forceDmlStatusCodeOverride != null)
            ? forceDmlStatusCodeOverride
            : e.getDmlType(0);
        OnboardingResponse errResp = new OnboardingResponse();
        errResp.onboard_type = onboardType;
        errResp.success = false;

        if (dmlType == StatusCode.DUPLICATE_VALUE
            || dmlType == StatusCode.DUPLICATES_DETECTED) {
            errResp.errorCode = 'DUPLICATE_RECORD';
            errResp.message   = 'Duplicate record detected. Original Salesforce error: '
                                + e.getDmlMessage(0);
        } else if (dmlType == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION
                   || dmlType == StatusCode.REQUIRED_FIELD_MISSING) {
            errResp.errorCode = 'VALIDATION_RULE_VIOLATION';
            errResp.message   = 'Salesforce validation rule rejected the request. Original Salesforce error: '
                                + e.getDmlMessage(0);
        } else {
            errResp.errorCode = 'SALESFORCE_DML_ERROR';
            errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                                + e.getDmlMessage(0);
        }

        return errResp;
    }

    /**
     * Handles a non-DML exception (e.g. thrown by a trigger or Flow without
     * using addError) raised during an Account/Contact insert or update.
     * Rolls back if a savepoint is provided and returns a SALESFORCE_DML_ERROR
     * envelope — the underlying save still failed, even though Apex did not
     * surface it as a DmlException.
     *
     * @param e            The caught exception
     * @param sp           Savepoint to roll back to; pass null when no DML preceded the failure
     * @param onboardType  The onboard type to echo back on the error envelope
     */
    private static OnboardingResponse buildGenericErrorResponse(
        Exception e,
        Savepoint sp,
        String onboardType
    ) {
        if (sp != null) {
            Database.rollback(sp);
        }

        OnboardingResponse errResp = new OnboardingResponse();
        errResp.onboard_type = onboardType;
        errResp.success   = false;
        errResp.errorCode = 'SALESFORCE_DML_ERROR';
        errResp.message   = 'The transaction was rolled back. Original Salesforce error: '
                            + e.getMessage();
        return errResp;
    }
}
