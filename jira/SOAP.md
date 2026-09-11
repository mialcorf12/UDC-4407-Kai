**Title:**
Migrate `KaiOnboardingService` from REST to SOAP API and Remove Platform Events

**Description:**
Business stakeholders have requested transitioning the Onboarding integration service from a REST API to a **SOAP API**. The `KaiOnboardingService` Apex class must be refactored to expose its capabilities via Apex WebService / SOAP.

Additionally, **all Platform Event publishing logic** (`EventBus.publish`) and its associated entities (`Sfdc_Accountuser_CreatedSuccess__e` and `Sfdc_Accountuser_CreatedFailed__e`) must be removed completely. The underlying business logic, field mappings, validation checks, and test coverage in `KaiOnboardingServiceTest` must be updated accordingly.

---

**Acceptance Criteria:**

* **SOAP API Refactoring:**
* Replace the `@RestResource` and `@HttpPost` annotations with Apex WebService modifiers (`webservice static OnboardingResponse handlePost(...)` or a signature tailored to the new SOAP contract).
* Remove all dependencies on `RestContext.request` and `RestContext.response`. HTTP status codes will no longer be set directly; instead, errors and status flags must be passed through the `OnboardingResponse` wrapper (e.g., `success`, `message`, `errorCode`).
* Preserve all existing business logic, validation rules (`validateInput`), dynamic RecordType resolution, field assignments, and atomic transaction handling via `Savepoint` / `Database.rollback`.


* **Platform Event Removal:**
* Remove all calls to `EventBus.publish(...)`.
* Delete the definitions and invocations of `publishSuccessEvent` and `publishFailedEvent`.
* Remove references to `Sfdc_Accountuser_CreatedSuccess__e` and `Sfdc_Accountuser_CreatedFailed__e`.
* Clean up `@TestVisible` capture lists (`capturedSuccessEvents` and `capturedFailedEvents`).


* **Unit Test Suite & Code Coverage (`KaiOnboardingServiceTest`):**
* Refactor the test class to eliminate `setupRestContext` and any assertions expecting `RestContext.response` or captured Platform Events.
* Update test scenario invocations to call the new SOAP method signature directly.
* Retain all core functional test scenarios (rollback verification, input validation gates, DML error classification, Branch A - Create, and Branch B - Update).
* Maintain code coverage at or above **85%**.



---

**Technical Tasks:**
* [ ] Refactor `KaiOnboardingService.cls`:
* [ ] Remove `@RestResource`, `@HttpPost`, `RestContext`, and event publisher methods (`publishSuccessEvent`, `publishFailedEvent`).
* [ ] Expose endpoint methods with the `webservice` keyword.
* [ ] Refactor `KaiOnboardingServiceTest.cls`:
* [ ] Remove RestContext helpers and Platform Event test assertions.
* [ ] Update all unit tests to assert directly against the returned `OnboardingResponse` object.
* [ ] Run Apex test suite and verify code coverage (`> 85%`).