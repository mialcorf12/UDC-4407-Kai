# User Story — Kai Onboarding Service

## Context

`KaiOnboardingService` is an Apex REST endpoint (`/services/apexrest/KaiOnboardingService/`) that lets the Kai onboarding portal create or update an Account and its linked Contact in Salesforce, mirroring the pattern already used by `UdcOnboardingService` for udesign.cloud onboarding. Same goal (atomic Account + Contact creation), different source system.

## User Story

**As** the Kai onboarding portal,
**I want** to POST organization and user data to a single Salesforce endpoint,
**so that** an Account and a linked Contact are created (or an existing Account is updated and a new Contact created) atomically, with clear, machine-readable error responses when something goes wrong.

## Endpoint Contract

`POST /services/apexrest/KaiOnboardingService/`

| HTTP Status | Meaning |
|---|---|
| 201 | Account + Contact created (Branch A), or Account updated + Contact created (Branch B) |
| 400 | Input validation failed — no DML executed |
| 404 | `org_sfdc_id` provided but no matching Account found |
| 409 | Duplicate record detected by a Salesforce Duplicate Rule |
| 422 | Salesforce Validation Rule or required-field constraint rejected the record |
| 500 | Unexpected DML error (trigger exception, lock timeout, etc.) — transaction rolled back |

Branch selection: `org_sfdc_id` blank/null → **Branch A** (create new Account); `org_sfdc_id` present → **Branch B** (update existing Account by Id, 404 if not found).

Both branches are wrapped in a `Savepoint`: if Contact insert fails after Account insert/update, the entire transaction rolls back.

## Business Rules — Field Mapping

Source: `applyAccountFields`, `applyAccountFieldsPartial`, and `buildContact` in `KaiOnboardingService.cls`.

### Payload → Account

| Payload field | Account field | Branch A | Branch B (partial merge) |
|---|---|---|---|
| `org_name` | `Name` | required | updated only if non-blank, else preserved |
| `org_type` | `Type` | set | updated only if non-blank |
| `org_status` | `Account_Status__c` | set | updated only if non-blank |
| `user.phone` | `Phone` | set | updated only if non-blank |
| `user.mailing_address_1/city/country/state/zipcode` | `Shipping*` and `Billing*` (same values used for both) | set | updated only if non-blank per sub-field |
| `license_number` | `License_Number__c` | set | updated only if non-blank |
| `user.email` | `Account_Email__c` | set | only set if currently blank |
| `user.last_name` | `Account_POC__c` | set | only set if currently blank |
| `org_id` | `Kai_Acct_Number__c` | set (skipped in test context) | set (skipped in test context) |
| n/a | `Date_Added_to_Kai__c` | `Date.today()` | `Date.today()` (always overwritten) |
| n/a (derived from `onboard_type == 'kai'`) | `Kai_Onboarding__c` | always set by endpoint logic | always set by endpoint logic |
| n/a | `RecordTypeId` | resolved to `Commercial` at insert | preserved from the existing record (not overwritten) |

### Payload → Contact (`buildContact`, shared by both branches)

| Payload field | Contact field |
|---|---|
| `user.first_name` | `FirstName` |
| `user.last_name` | `LastName` |
| `user.email` | `Email` |
| `user.phone` | `Phone` |
| `user.cell_phone` | `MobilePhone` |
| `user.user_type` | `Company_User_Type__c` (`'Customer Account Owner'` → `'Account Owner'`, otherwise passed through) |
| `user.role` | `Contact_Role__c` |
| `user.user_id` | `Kai_User_ID__c` |
| `user.activation_url` | `Kai_Activation_URL__c` |
| `user.mailing_address_1/city/country/state/zipcode` | `Mailing*` |
| n/a (derived) | `Kai_Onboarding__c` |
| n/a | `RecordTypeId` resolved to `Commercial` |

### Validation (pre-DML, `validateInput`)

- `org_name` required on Branch A only (not required on Branch B, where the existing Account may already have a name).
- `user.last_name` always required.
- `user.email` must match an RFC-compatible email regex.
- Any failure short-circuits with HTTP 400 `INVALID_INPUT` before any DML and still publishes a failed Platform Event.

### Platform Events

- `Sfdc_Accountuser_CreatedSuccess__e` published after both records commit (Account Id, Contact Id, `org_id`, `user_id`, `onboard_type`).
- `Sfdc_Accountuser_CreatedFailed__e` published on every non-201 outcome, carrying `Status_Code__c`, `Error_Code__c`, `Error_Message__c` (truncated to 255 chars), and the Account Id only if one was actually committed before the failure.
- Both events use `PUBLISH_IMMEDIATELY`, so they survive DML rollback (a failed event is still emitted even when the transaction is rolled back).
- Publish failures are swallowed — they must never alter the HTTP response.

## Acceptance Criteria (Gherkin)

Each scenario below is covered by an existing test in `KaiOnboardingServiceTest.cls`.

```gherkin
Scenario: Missing org_name on new-Account payload
  Given a POST payload with org_sfdc_id blank and org_name null
  When the request is received
  Then the response status is 400 with errorCode INVALID_INPUT
  And no Account is inserted

Scenario: Missing user.last_name
  Given a POST payload with user.last_name null
  When the request is received
  Then the response status is 400 with errorCode INVALID_INPUT

Scenario: Malformed email
  Given a POST payload with an invalid user.email
  When the request is received
  Then the response status is 400 with errorCode INVALID_INPUT

Scenario: Successful creation with onboard_type = kai
  Given a valid payload with org_sfdc_id blank and onboard_type "kai"
  When the request is received
  Then the response status is 201
  And a new Account is created with Kai_Onboarding__c = true
  And a new Contact is created and linked to that Account with Kai_Onboarding__c = true

Scenario: Successful creation without onboard_type
  Given a valid payload with org_sfdc_id blank and onboard_type omitted
  When the request is received
  Then the response status is 201
  And Kai_Onboarding__c is false on both the Account and the Contact

Scenario: Contact insert fails after Account insert (Branch A)
  Given a valid payload that triggers a forced Contact DML failure
  When the request is received
  Then the response status is 500 with errorCode SALESFORCE_DML_ERROR
  And the Account does not persist in the database (rollback verified)

Scenario: Account insert fails (Branch A)
  Given a payload whose org_name exceeds the 255-character field limit
  When the request is received
  Then the response status is 500 with errorCode SALESFORCE_DML_ERROR
  And no Contact is created

Scenario: org_sfdc_id provided but Account not found (Branch B)
  Given a payload with a well-formed but non-existent org_sfdc_id
  When the request is received
  Then the response status is 404 with errorCode ACCOUNT_NOT_FOUND
  And no DML is executed

Scenario: org_sfdc_id matches an existing Account (Branch B)
  Given a payload with org_sfdc_id pointing to a pre-existing Account
  When the request is received
  Then the response status is 201
  And the existing Account is updated (no new Account is created)
  And a new Contact is created and linked to the existing Account

Scenario: Branch B preserves fields omitted from the payload
  Given an existing Account with Phone and ShippingCity already populated
  And a payload that omits user.phone and user.mailing_city
  When the request is received
  Then Phone and ShippingCity on the Account keep their original values
  And fields present in the payload (Name, ShippingStreet, License_Number__c) are updated

Scenario: DML classified as a duplicate
  Given an Account DML failure whose StatusCode is DUPLICATE_VALUE / DUPLICATES_DETECTED
  When the request is received
  Then the response status is 409 with errorCode DUPLICATE_RECORD

Scenario: DML classified as a validation rule violation
  Given a DML failure whose StatusCode is FIELD_CUSTOM_VALIDATION_EXCEPTION / REQUIRED_FIELD_MISSING
  When the request is received
  Then the response status is 422 with errorCode VALIDATION_RULE_VIOLATION

Scenario: Malformed JSON payload
  Given a request body that is not valid JSON
  When the request is received
  Then the response status is 500 with errorCode INTERNAL_ERROR
  And a Sfdc_Accountuser_CreatedFailed__e is published with all identifiers null

Scenario: Success event published after Branch A / Branch B
  Given a successful onboarding request (either branch)
  When the request completes with HTTP 201
  Then exactly one Sfdc_Accountuser_CreatedSuccess__e is published
  And it carries the created/updated Account Id, the new Contact Id, org_id and user_id
  And zero Sfdc_Accountuser_CreatedFailed__e are published

Scenario: Failed event published despite DML rollback
  Given a forced Contact DML failure after the Account was already committed
  When the request is received
  Then the Account is rolled back and does not persist
  But exactly one Sfdc_Accountuser_CreatedFailed__e is still published
  And it carries the Account Id that existed at publish time (PUBLISH_IMMEDIATELY survives rollback)
```

## Related Metadata
** New fields**
- `Account.Kai_Onboarding__c` — Checkbox, default false. "Indicates that this Account was created through the Kai onboarding portal."
- `Account.Kai_Acct_Number__c` — Number(6,0), external ID, unique.
- `Account.Date_Added_to_Kai__c` — Date.
- `Account.Account_Status__c` — Picklist ("Company Status"). Add new value -> Kai Account
- `Contact.Kai_Onboarding__c` — Checkbox, default false.
- `Contact.Kai_Activation_URL__c` — Url.
- `Contact.Kai_User_ID__c` — Text(10), external ID, unique.
- `Contact.Kai_Invite_Email_Sent__c` — Date (not yet wired into `KaiOnboardingService.cls`).
- `sfdc_accountuser_createdSuccess__e.OnboardType__c` and the equivalent under `sfdc_accountuser_createdFailed__e/` — Text(15), the only new Platform Event field added for Kai.

**Pre-existing fields** in the target org, reused from the UDC onboarding flow:
- `Account.License_Number__c`, `Account.Account_Email__c`, `Account.Account_POC__c`
- `Contact.Contact_Role__c`, `Contact.Company_User_Type__c`
- Platform Event fields `AcctCaseSafeID__c`, `uLab_Acct_Number__c`, `ContactCaseSafeID__c`, `Portal_User_ID__c` (success event) and additionally `Status_Code__c`, `Error_Code__c`, `Error_Message__c` (failed event)


## Org Dependencies (not deployed from this repo)

- `RecordType` `Commercial` must already exist on both Account and Contact in the target org — `KaiOnboardingService.cls` resolves it dynamically by Developer Name (`Schema.SObjectType.*.getRecordTypeInfosByDeveloperName().get('Commercial')`) 
- No Permission Set, Remote Site Setting, or Named Credential is versioned in this repo for this endpoint — access to `/services/apexrest/KaiOnboardingService/` must be granted and verified directly in the org.

## Out of Scope / Resolved Questions

- **"Kai MRA assigned"** — mentioned as a desired new field in the original draft (`jira/us.md`). Not implemented: no metadata field and no reference in `KaiOnboardingService.cls`. Treated as out of scope until a follow-up ticket defines it.
- **Platform Events: reuse UDC's or create new ones for Kai?** (open question) — Resolved: the existing UDC events (`Sfdc_Accountuser_CreatedSuccess__e` / `...Failed__e`) are reused as-is; the only addition was the `OnboardType__c` field on both, so downstream subscribers can distinguish the onboarding source.
