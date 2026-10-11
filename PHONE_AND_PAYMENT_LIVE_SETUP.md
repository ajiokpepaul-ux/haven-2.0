# Phone and Paystack setup

This file supersedes the earlier Stripe setup notes. The current build uses Paystack's split-payment API for NGN listings, pending account eligibility approval and end-to-end tests.

- Required guest phone and WhatsApp are validated in the booking form and in the `request_booking` database function.
- Paystack checkout sends the guest to a provider-hosted page; Haven never collects card details directly.
- A host subaccount is configured with a 5% share for Haven's main account. Paystack transaction fees are assigned to the host subaccount in this build; disclose and confirm this with the provider.
- Only the signed `charge.success` webhook, after server-side Paystack transaction verification, marks the booking paid.

Follow `IMPLEMENTATION_AND_RECOVERY_GUIDE.md` for exact steps, SQL migration, function deployment and test-mode webhook setup.

**Under-18 founder requirement:** do not register with a false age or borrow an adult's identity. An eligible adult or legal business must genuinely own/manage the payment account, complete required verification and accept responsibility. Ask Paystack to confirm in writing that Haven's accommodation marketplace and split model are eligible before accepting real money.

Never store secret keys or raw host bank account numbers in `config.js`, browser code or GitHub. This implementation sends host bank details to the server function, which forwards them to Paystack and stores only the returned subaccount reference in Supabase.
