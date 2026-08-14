POST 
/services/apexrest/UdcOnboardingService/
{
    "org_id": 1,
    "onboard_type": "udesign.cloud",
    "is_parent": true,
    "org_name": "UDC OrgName",
    "org_type": "Orthodontic Practice",
    "org_status": "uLab Account",
    "shipping_address_1": "17098 TUPPER ST",
    "shipping_city": "LATHROP",
    "shipping_zip": "95330",
    "shipping_address_id": 586809,
    "shipping_country": "US",
    "shipping_region": "CA",
    "phone": "12222299999",
    "billing_address_1": "17098 TUPPER ST",
    "billing_city": "LATHROP",
    "billing_zip": "95330",
    "billing_address_id": 586810,
    "billing_country": "US",
    "billing_region": "CA",
    "license_number": "1",
    "tou_accepted_flag": true,
    "tou_updated_ts": "2026-08-07",
    "cloud_customer": true,
    "cloud_assignment": "2026-08-07",
    "user": {
      "user_id": 1,
      "first_name": "UDC Contact",
      "last_name": "Record",
      "email": "udcContactRecord@mailinator.com",
      "phone": "11222299911",
      "cell_phone": "11222299911",
      "user_type": "Customer Account Owner",
      "role": "Orthodontist",
      "mailing_city": "LATHROP",
      "mailing_country": "US",
      "mailing_zipcode": "95330",
      "mailing_address_1": "17011 TUPPER ST",
      "mailing_address_id": 586801,
      "mailing_state": "CA",
      "mailing_phone": "11222299911",
      "activation_url": "https://qa.udesign.cloud/auth/activation/?token=H1Z3hKugUbje53e3A-n7",
      "user_role_added": true
    }
  }


  POST
  /services/apexrest/KaiOnboardingService/

  // new account + new contact
{
    "org_id": 2,
    "onboard_type": "kai",
    "org_name": "KAI OrgName",
    "org_type": "Orthodontic Practice",
    "org_status": "kai Account",
    "license_number": "2",
    "user": {
      "user_id": 2,
      "first_name": "KAI",
      "last_name": "Record",
      "email": "kaiContactRecord@mailinator.com",
      "phone": "222222222",
      "cell_phone": "222222222",
      "user_type": "Customer Account Owner",
      "role": "Orthodontist",
      "mailing_city": "Orem",
      "mailing_country": "US",
      "mailing_zipcode": "84097",
      "mailing_address_1": "428 E 750 S",
      "mailing_state": "UT",
      "activation_url": "https://qa.udesign.cloud/auth/activation/?token=H1Z3hKugUbje53e3A-x8"
    }
  }

// existing account + new contact
  {
    "org_id": 2,
    "org_sfdc_id": "001VA00001Vr2irYAB",
    "onboard_type": "kai",
    "org_name": "KAI OrgName",
    "org_type": "Orthodontic Practice",
    "org_status": "kai Account",
    "license_number": "2",
    "user": {
      "user_id": 3,
      "first_name": "KAI",
      "last_name": "Record",
      "email": "kai3ContactRecord@mailinator.com",
      "phone": "333333333",
      "cell_phone": "333333333",
      "user_type": "Account Manager",
      "role": "Orthodontist",
      "mailing_city": "Orem",
      "mailing_country": "US",
      "mailing_zipcode": "84097",
      "mailing_address_1": "428 E 750 S",
      "mailing_state": "UT",
      "activation_url": "https://qa.udesign.cloud/auth/activation/?token=H1Z3hKugUbje53e3A-y3"
    }
  }