# Haven — listing, booking and payment reliability update

This update is built on the existing Haven project (static HTML/CSS/JS + Supabase + Vercel). It fixes the async listing-save bug, makes photo upload failures visible, adds a host listing-status workspace, expands property/booking forms, and includes a Paystack split-payment implementation for **NGN test-mode setup**.

## Important before using live payments

- The Paystack code is not activated just by uploading the files. It needs Supabase Edge Function deployment, a Paystack secret in Supabase, a configured webhook, and end-to-end tests.
- Paystack must explicitly approve Haven's accommodation marketplace and split-payment model. The platform account must be owned/managed by an eligible adult or legal business because the founder is under 18. Do not misstate age, business type, or account ownership.
- This version initializes split checkout in NGN only. Other currencies are not enabled for checkout in this build.
- In a split payment, Paystack routes the configured share to Haven's main account and the remaining share to the host subaccount. This version configures 5% for Haven. Paystack processing fees are assigned to the host subaccount in the checkout request; make this clear in host terms and confirm the provider's final settlement behavior.
- No secret keys are stored in browser files. Keep `PAYSTACK_SECRET_KEY` and the Supabase service-role key out of `config.js`, GitHub and chat.

## Files

- `index.html`, `styles.css`, `app.js` — homepage, listing form, gallery, booking form, listing status and booking dashboard.
- `config.js` — existing browser-safe Supabase URL and publishable key. Preserve your current copy.
- `supabase/migrations/20261011_haven_reliability_upgrade.sql` — status trigger, storage rules, property fields, required guest phone/WhatsApp and updated booking RPC.
- `supabase/functions/start-host-onboarding/` — creates/updates a Paystack host subaccount using the host's bank details; bank details are sent to Paystack and not stored by Haven.
- `supabase/functions/create-checkout/` — server-side Paystack checkout with a 5% platform split.
- `supabase/functions/paystack-webhook/` — verifies Paystack's signature and re-verifies successful transactions before marking a booking paid.
- `docs/IMPLEMENTATION_AND_RECOVERY_GUIDE.md` — step-by-step existing-project setup and troubleshooting.
- `docs/PRODUCTION_CHECKLIST.md` — launch safety checks.

## Apply the update to your existing project

1. Back up the GitHub repository and Supabase database first.
2. In Supabase SQL Editor, run `supabase/migrations/20261011_haven_reliability_upgrade.sql` once. It is designed as an idempotent upgrade for the existing Haven Phase 2 database; do not run the legacy `schema.sql` over a live database.
3. Upload/commit `index.html`, `styles.css`, `app.js`, `supabase/migrations/20261011_haven_reliability_upgrade.sql`, and the updated function folders to the same GitHub repo connected to Vercel. Keep the existing `config.js`.
4. Deploy the Edge Functions and configure test secrets as shown in the recovery guide.
5. Configure the Paystack test webhook, then test listings, booking, split and webhook using test accounts only.
6. Only consider live mode after written provider approval, adult/legal account ownership, policy review and successful end-to-end testing.

## Why a listing did not appear after changing status

Haven's public homepage intentionally queries only `properties.status = 'published'`. `verification_status` is a separate review field. In Supabase Table Editor, set **`verification_status` to `verified`** (not the `status` column). The new database trigger will set `status` to `published`. If the page is already open, click **Refresh homes** or reload the page.

Valid `verification_status` values: `not_reviewed`, `submitted`, `in_review`, `verified`, `rejected`, `expired`.

Valid `status` values in the existing Phase 2 schema: `draft`, `pending_review`, `published`, `rejected`, `suspended`.

## Payment flow

1. Guest requests a stay with required phone and WhatsApp numbers.
2. Host accepts the request.
3. Host configures a Paystack subaccount using a valid bank code and account number.
4. Guest clicks **Continue to payment**. The server calculates the amount from the saved booking, initializes Paystack checkout and sends the guest to Paystack's hosted page.
5. Paystack sends `charge.success` to `paystack-webhook`. The webhook validates the HMAC signature and calls Paystack's transaction verification endpoint. It checks the amount/currency/reference against the booking before marking the booking paid.

A browser redirect is not proof of payment. Never mark a booking paid manually just because the guest sees a success page.
