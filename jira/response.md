# Response — Action Items Assigned to @Alberto Cordero

Reference: `jira/requirement.md` — KAI Onboarding integration with SFDC, Boomi, and NetSuite.

This response reuses the existing `UdcOnboardingService` Apex REST endpoint and the existing MRA/pricing Flows that already support uDesign Cloud (uDC) onboarding, extending them for a new `onboard_type: "kai"` rather than introducing new mechanisms.

---

## 1. Mandatory fields for Organization and User creation (line 29)

**Current mechanism:** `force-app/main/default/classes/UdcOnboardingService.cls` exposes a REST endpoint (`/UdcOnboardingService/*`) that accepts an `OnboardingRequest` payload (Organization) with a nested `ContactRequest` (User). This is the existing contract used by uDC onboarding today.

**Proposed approach for KAI:** Reuse the same payload contract for KAI onboarding. Based on `validateInput()` and the fields actually persisted to Account/Contact, the mandatory fields are:

- **Organization (Account):** `org_name` (required — validation fails without it on new-Account creation), plus practically required for a usable record: `org_type`, `org_status`, billing/shipping address set (street, city, country, region, zip), `phone`.
- **User (Contact):** `user.last_name` (required by validation), `user.email` (required, must pass RFC-compatible regex validation), plus `first_name`, `role`, `user_type` for a functional record.

**Dependency/Blocker:** None — this is derivable directly from the existing Apex contract. Confirm with the KAI team whether their payload will match this schema or need a mapping layer.

---

## 2. Handle user duplication in SFDC (line 30)

**Current mechanism:** `UdcOnboardingService` currently uses `Database.DMLOptions.DuplicateRuleHeader.allowSave = true` on every Account/Contact insert and update (`UdcOnboardingService.cls` lines 292-295, 376-379, 623-626). This **bypasses** Salesforce Duplicate Rules rather than deduplicating — a duplicate record is still created. The only duplicate-related behavior today is that if a `DmlException` with `DUPLICATE_VALUE`/`DUPLICATES_DETECTED` reaches `buildDmlErrorResponse` (lines 794-799), the endpoint returns HTTP 409 — but this path is not currently reachable while `allowSave = true` is set, since that flag suppresses the duplicate error.

**Proposed approach for KAI:** Since the same user may be onboarded through both KAI and uDC, add an explicit pre-insert lookup when `onboard_type == "kai"`: query existing Contacts by `Email` (and/or a shared external identifier, if one is agreed with KAI) before creating a new Contact. If a match is found, update/link the existing Contact instead of inserting a duplicate, mirroring the existing "update existing Account" (Branch B) pattern already implemented for Accounts via `org_sfdc_id`.

**Dependency/Blocker:** Requires agreement on the matching key between KAI and SFDC (email vs. a shared external ID) — related to the mandatory-fields discussion in item 1.

---

## 3. Default pricing tier for new KAI users (line 33)

**Current mechanism:** Pricing is not assigned by Apex. It is handled by two Flows on `Marketing_Reward_Association__c` (MRA):
- `Record_Trigger_Copy_pricing_fields_on_MRA_record_from_MR_record_on_Effective_date` (record-triggered on MRA create, when `Effective_Date_Today__c = true`) copies ~20 pricing/bundle fields (Aligner_Price__c, Retainer_Price__c, STL_Price__c, Custom_Packaging_*, uAssist_*_Pricing__c, etc.) from the related `Marketing_Reward__c` (MR) master record onto the MRA, branching by MRA RecordType (`Program_Association` vs `Promotion_Association`).
- `Copy_pricing_fields_on_MRA_record_from_MR_record_on_Effective_date` is a daily scheduled Flow that re-syncs the same fields for any MRA whose `Effective_Date__c = TODAY()`.

**Proposed approach for KAI:** These Flows key off MRA RecordType and the related MR master record, not off onboarding source — so no changes are needed here once a KAI-relevant MRA record exists on the Account (see item 4). The "default pricing tier" for a new KAI user is effectively whichever MRA program is created for their Account.

**Dependency/Blocker:** Same as item 4 — depends on which MRA program(s)/RecordType should apply to KAI accounts by default.

---

## 4. Create MRA or bundles for KAI in SFDC (line 38)

**Current mechanism:** `force-app/main/default/flows/Create_MRAs_for_New_Accounts.flow-meta.xml` is a record-triggered Flow on Account (after save, create/update) that creates 5 MRA records per new Account — one per program (uStart, Custom Packaging, STL100, uAssist 100, STLONE) — when `uLab_Acct_Number__c` is not null, `MRAs_Applied__c` is null, and `Date_Added_to_Portal__c > 2025-03-28`. It then stamps `MRAs_Applied__c` on the Account so it only runs once.

**Proposed approach for KAI:** Add a KAI-specific branch (or extend entry criteria) to this Flow, gated by a KAI-equivalent onboarding flag (analogous to how `UDC_Onboarding__c` marks uDC-sourced Accounts in `UdcOnboardingService.cls`), so new KAI Accounts get the correct MRA/bundle set created automatically. The pricing-copy Flows in item 3 require no change, since they operate downstream on MRA records regardless of onboarding source.

**Dependency/Blocker:** This cannot be finalized until @Don Sharma provides the list of bundles applicable to KAI (`jira/requirement.md` line 34). No "KAI" RecordType currently exists for `Marketing_Reward_Association__c`/`Marketing_Reward__c` in the org metadata — one will need to be created (or an existing program reused) once the bundle list is known.

---

## Summary of Cross-Cutting Dependency

Items 3 and 4 are effectively the same piece of work (creating the right MRA records for KAI Accounts) and are both blocked on the KAI bundle list from @Don Sharma. Items 1 and 2 can proceed independently once the KAI team confirms their onboarding payload will follow the existing `OnboardingRequest`/`ContactRequest` contract.
