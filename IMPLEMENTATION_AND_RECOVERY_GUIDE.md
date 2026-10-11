# Haven — implementation and recovery guide

## Before you start

- Live website: `https://haven-tau-ruddy.vercel.app/`
- Supabase project ref: `bmiqngjtfyaodlguatxg`
- SQL Editor: `https://supabase.com/dashboard/project/bmiqngjtfyaodlguatxg/sql/new`
- Supabase Functions: `https://supabase.com/dashboard/project/bmiqngjtfyaodlguatxg/functions`
- GitHub repo: `https://github.com/ajiokpepaul-ux/haven-2`

Back up the repository and database first. Do not share secret keys. The `config.js` file contains a browser-safe publishable key and must retain the existing project URL/key.

## A. Fix listing status so approved properties appear

1. Extract the ZIP and open `haven-work/supabase/migrations/20261011_haven_reliability_upgrade.sql`.
2. Copy the entire file into Supabase SQL Editor and click Run.
3. Open Table Editor → `properties`.
4. Find the property row by its listing ID.
5. Set `verification_status` to `verified`. Do **not** type `verified` into the `status` column; `status` is a separate field.
6. Save the row. The trigger sets `status` to `published` automatically.
7. Open Haven and click **Refresh homes**. You can also reload the page.

If the trigger does not publish it, check the SQL Editor output for an error, confirm the trigger exists under Database → Triggers, and inspect both fields. If a property is suspended, the trigger preserves the suspension.

## B. Upload the new website files

1. Open the existing GitHub repository connected to Vercel.
2. Replace `index.html`, `styles.css`, and `app.js` with the versions in `haven-work/`.
3. Upload the new SQL migration and the three Edge Function folders under `supabase/functions/`.
4. Keep the existing `config.js`; do not replace it with `config.example.js`.
5. Commit the changes and wait for Vercel to finish the deployment.
6. In the browser, hard-refresh with Ctrl+F5.

The new host workspace lists drafts as well as published properties. The public Explore section continues to show published homes only.

## C. How photo upload now works

1. Sign in first.
2. Complete the listing form, including required description, rules and at least one real photo.
3. Submit once and wait for the progress bar to finish. Avoid refreshing while uploading.
4. A successful listing shows a listing ID and appears in **Your homes on Haven** as `draft · not reviewed`.
5. If upload fails, the form displays the actual error (for example, storage bucket or policy problem). Partial photos and the temporary draft are cleaned up where possible so a retry does not create a broken public listing.

The migration creates/configures the public-read `haven-listing-images` bucket and host-owned upload/delete policies. Only a signed-in user can upload into their own user-ID folder.

## D. Configure Paystack in test mode

Paystack must approve the platform account and accommodation marketplace/split-payment model. Because the founder is under 18, an eligible adult or legal business must genuinely own/manage the provider account and assume its responsibilities. Do not create an account with a false age or false business description.

1. Create/access the approved Paystack dashboard and use **Test mode**.
2. In Supabase → Edge Functions → Secrets, add:
   - `PAYSTACK_SECRET_KEY` = the Paystack test secret key (`sk_test_...`)
   - `SITE_URL` = `https://haven-tau-ruddy.vercel.app`
   - `SITE_ORIGIN` = `https://haven-tau-ruddy.vercel.app`
3. Deploy these functions from the extracted project directory:

```bash
supabase login
supabase link --project-ref bmiqngjtfyaodlguatxg
supabase functions deploy start-host-onboarding
supabase functions deploy create-checkout
supabase functions deploy paystack-webhook --no-verify-jwt
```

Supabase injects the project URL and service-role key for Edge Functions in the hosted environment. If your project settings differ, configure them through Supabase secrets; never expose the service-role key in browser code.

4. In Paystack Test Dashboard → Settings → API Keys & Webhooks, add this webhook URL:

`https://bmiqngjtfyaodlguatxg.supabase.co/functions/v1/paystack-webhook`

5. Use the test-mode bank account data and bank codes supplied by Paystack. Sign in as a host, open the host bank settlement form, and submit the host account/business name, bank code and 10-digit account number. The server creates a subaccount with a 5% main-account share. Haven does not store the raw account number.
6. Create a listing in NGN, publish it after review, and request a booking from a separate guest account.
7. Host accepts the request. Guest clicks **Continue to payment** and completes Paystack's test checkout.
8. Check Supabase `bookings`: `payment_status` should become `paid` only after the signed webhook has verified the transaction. Check `payment_events` for the recorded event.

If Paystack refuses subaccount creation, checkout or the split, do not bypass the error. Ask Paystack to confirm the account and business eligibility and bank-code format.

## E. Payment split design

Paystack subaccount `percentage_charge: 5` configures 5% for the main platform account and the remainder for the host subaccount. The checkout sets `bearer: subaccount`, so processing charges are assigned to the host subaccount in this implementation. Confirm these settlement terms with Paystack and disclose them to hosts. Refunds, cancellations, disputes, taxes and settlement reconciliation still need a written policy and operational handling.

This build initializes Paystack checkout only for `NGN`. Do not publish non-NGN properties as payable until an approved provider/currency implementation exists.

## F. Common errors

- **Listing saves but does not appear:** check `verification_status = verified` AND `status = published`; then click Refresh homes. The new trigger should sync those fields.
- **`permission denied for table properties`:** rerun the reliability migration and inspect `Published properties are public`, `Hosts view own properties`, and `Hosts create own drafts` policies.
- **Photo upload fails:** inspect Storage → Buckets → `haven-listing-images`; verify it is public for image viewing and that the authenticated upload policy checks the first folder is the signed-in user's UUID.
- **`column gallery_urls does not exist`:** the reliability migration was not applied to the database connected by `config.js`.
- **`function request_booking does not exist`:** apply the reliability migration, then hard-refresh the website.
- **Paystack function says secrets missing:** confirm `PAYSTACK_SECRET_KEY`, `SITE_URL`, and `SITE_ORIGIN` are saved in Supabase Edge Function Secrets and redeploy the functions.
- **Host has no subaccount:** the host must complete the bank settlement setup first; use valid test bank details and bank code.
- **Currency error:** this implementation supports NGN split checkout only.
- **Payment redirects back but remains unpaid:** inspect the Paystack webhook delivery log and Supabase function logs. Never manually set `paid` to bypass verification.

## G. Go-live gate

Do not switch to live keys until Paystack confirms in writing that Haven's accommodation marketplace and split model are eligible; the platform account is correctly owned/managed; host bank subaccounts are approved; test payments and webhooks work; refund/cancellation/dispute workflows are documented; and legal/privacy/tax responsibilities have been reviewed.
