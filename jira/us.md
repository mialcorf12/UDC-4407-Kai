Vamos a construir hay un kaiOnboardingService tomando como referencia udcOnboardingService. Ambas clases tienen el mismo objetivo crear Account y Contact en salesforce de forma simultánea, pero la diferencia es el sistema origen de la información.

Account
Record type = commercial
Account Name
Account Type = Clinical practice, Dental lab or Manufacturing
License Number
* new fields   
Kai Acct Number (External id unique)
Kai Onboarding (checkbox=true)
Kai MRA assigned

Contact
First Name 
Last Name (also Account POC)
Phone
Mobile Phone
Email (also Company Email)
* new fields   
Kai_User_ID__c (External id unique)

Address
Address Id
Street
Country
City 
State
Postal Code



open questions:
1) Cómo vamos a manipular la generación de los eventos? Vamos a utilizar los mismos plaforms events éxito y fallo que existen para UDC o vamos a crear nuevos para KAI?


Contact Role
Company User Type
Account Owner