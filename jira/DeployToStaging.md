# turn off process failed, first disabled, deploy, enabled
Version 14: Invite Customer - Contact Updates
Version 3: Send to NetSuite - Contact
Version 5: Update ASD Email
ValidationRule Onboarding_Account_Owner 


# new changes
## UDC-4407
create a new version for 
- Process Builder - NFA Create
    - Customer Onboarded 
        1. [Account].uLab_Acct_Number__c Greater than or equal NUMBER 6216
        2. [Account].Kai_Acct_Number__c Is null Boolean False
        3. [Account].New_Acct_NFAs_Created__c Equals Boolean False
        Customize the logic
        Logic: (1 OR 2) AND 3





# ?????? Process Builder - Create MRAs for New Accounts ?????


# post deploy task
- field visibility
- add fields in a new layout section









# no need changes
- Process Builder - New Customer Feature Flag Update - NFA
- Process Builder - Create MRA send to Boomi
- Process Builder - Create Futures MRA
