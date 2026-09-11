## Exploration: KaiOnboardingService SOAP Migration

### Current State
`KaiOnboardingService` is an Apex REST endpoint (`@RestResource`) that processes unitary JSON requests to atomically create or update an Account and insert a linked Contact. It manages transactions via a single `Savepoint` and `Database.rollback`. It also leverages `RestContext` to set HTTP response codes (201, 400, 404, 409, 422, 500) and publishes `Sfdc_Accountuser_CreatedSuccess__e` and `Sfdc_Accountuser_CreatedFailed__e` Platform Events for observability.

### Affected Areas
- `force-app/main/default/classes/KaiOnboardingService.cls` — Primary endpoint logic, wrappers, transaction management, and EventBus integrations.
- `force-app/main/default/classes/KaiOnboardingServiceTest.cls` — Unit test suite relying on `RestContext`, JSON payloads, and `@TestVisible` Platform Event captures.

### Approaches
1. **Direct Signature Swap (Unitary)**
   - Change `@RestResource`/`@HttpPost` to `webservice static OnboardingResponse handlePost(OnboardingRequest req)`. Add `webservice` modifiers to all properties inside the inner wrapper classes so they appear in the WSDL. Remove all REST Context and Platform Event logic.
   - Pros: Directly preserves the existing transaction rollback (`Savepoint`) and field mapping logic exactly as specified in the Acceptance Criteria. Lowest risk of business logic regression.
   - Cons: Remains a unitary endpoint. Apex best practices generally require collection-based processing.
   - Effort: Low

2. **Bulkified SOAP Endpoint (List)**
   - Refactor the signature to `webservice static List<OnboardingResponse> handlePost(List<OnboardingRequest> reqs)`. Move DML outside loops using partial-success `Database.insert(records, false)` and iterate over `SaveResult` objects.
   - Pros: Follows Apex limits and bulkification best practices. Supports 250+ bulk testing natively.
   - Cons: Violates the explicit Acceptance Criteria constraint to "Preserve... atomic transaction handling via Savepoint / Database.rollback". `Savepoint` rollback in bulk DML loops is highly complex and breaks partial-success patterns.
   - Effort: High

### Recommendation
**Direct Signature Swap (Unitary)**. Given the strict Acceptance Criteria to preserve the atomic `Savepoint` rollback logic, the service should remain unitary for this migration scope. Applying 250+ record bulkification to the endpoint would require a complete redesign of the atomic parent-child transaction boundary, contradicting the user story constraints. The tests will be refactored to directly call the unitary SOAP method without `RestContext`, and the 250+ record bulk test requirement should be scoped down to reflect the unitary design, or handled by calling the endpoint iteratively in a test loop (which risks governor limits).

### Risks
- **Breaking Integration**: Upstream consumers must completely swap their JSON/REST integration for an XML/SOAP integration based on the generated Enterprise/Apex WSDL.
- **Loss of Observability**: Downstream systems listening for the Platform Events will immediately stop receiving data.
- **Error Handling**: Consumers must be instructed to inspect `success` and `errorCode` inside the SOAP response body rather than relying on HTTP Status Codes (e.g., 400, 404, 500).

### Ready for Proposal
Yes. The orchestrator can proceed with proposing the unitary SOAP migration.