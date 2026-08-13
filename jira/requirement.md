# KAI Onboarding

# Introduction

This page documents the assumptions, open questions, and action items for KAI onboarding integration with uLab systems like Salesforce, Boomi and Netsuite.

# Workflow
workflow.png

# Assumptions

- The Organization and User records are already created in the KAI database.
- User role management is handled within KAL
- An organization can have multiple users.
- User activation is handled by KAL (For uDC, SFDC sends the user activation email.)
- User approval, including DocuSign and license approval, is handled in SFDC.
- User account management, including password changes and reset/forgot-password functionality, is handled by KAL
- When user details are updated in either SFDC or KAI, Boomi will synchronize the changes to ensure KAI has the latest information.

# Open Questions

- Is session management / SSO handled by KAI?
- Is address validation handled during user onboarding? An invalid address could impact shipping.
- Is the enablement/disablement of KAI features—such as Scanner, Reva, Admin User Management, etc.—handled within KAI?
- Does KAI have the concept of assignees? If so is assignee management handled within KAI?

# Action Items

- [ ] @Sandip Patel (or) @Alberto Cordero, Share the mandatory fields required for Organization and User creation.
- [ ] @Sandip Patel (or) @Alberto Cordero, Handle user duplication in SFDC, as the same user may be onboarded in both KAI and uDC.
- [ ] @Andrew Liu , Share the KAI database credentials, schema, and fields mapping with Megha and Kasi to support development of the Boomi workflows.
- [ ] @Megha Pidapa : Create a Boomi workflow to retrieve user details from the KAI database and create the corresponding user in SFDC.
- [ ] @Sandip Patel (or) @Alberto Cordero, Create a default pricing tier and assign it to all newly created KAI users.
- [ ] @Don Sharma : Provide the list of bundles applicable to KAL.
- [ ] @Julien Pelletier-Morin : Create a NetSuite script to create users in NetSuite.
- [ ] @Megha Pidapa : Create a Boomi workflow to retrieve newly created users from SFDC and provide the required information to NetSuite for user creation.
- [ ] @Megha Pidapa : Create a Boomi workflow to fetch newly created User’s SFDC ID and update KAI database
- [ ] @Sandip Patel (or) @Alberto Cordero: Create MRA or bundles for KAI in SFDC
- [ ] @Julien Pelletier-Morin : Create the KAI bundles in Netsuite

# Decisions

- **KAI MVP will not use OKTA. User migration from KAI user management to OKTA will be handled post MVP release.**