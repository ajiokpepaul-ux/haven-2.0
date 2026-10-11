# Haven production checklist

## Database and listings
- [ ] Back up Supabase and GitHub before applying migrations.
- [ ] Apply `20261011_haven_reliability_upgrade.sql` successfully.
- [ ] Confirm a new draft and photo URLs save in `properties` and Storage.
- [ ] Confirm `verification_status = verified` triggers `status = published`.
- [ ] Confirm suspended listings stay suspended and public queries exclude drafts.
- [ ] Confirm public clients cannot read `address_private` or reviewer notes.

## Guest booking
- [ ] Phone and WhatsApp are both required and validated.
- [ ] Host can view guest phone/WhatsApp only for a booking they host.
- [ ] Check-in/out, guest limits, min/max nights and overlap checks work.
- [ ] Special request and arrival time persist with the booking.

## Paystack test mode
- [ ] Paystack confirms the platform and accommodation marketplace/split model are eligible.
- [ ] Platform account is owned/managed by an eligible adult or business and all KYC is complete.
- [ ] Host subaccount creation/update works with test details.
- [ ] `create-checkout` uses the stored booking amount and host subaccount.
- [ ] Haven's 5% share and host payout/processing-fee allocation match the written host terms.
- [ ] Webhook signature verification and server-side transaction verification pass.
- [ ] Duplicate webhooks do not create duplicate payment records.
- [ ] Failed/cancelled payments do not mark bookings paid.
- [ ] Refunds, cancellations, disputes and reconciliation are tested and documented.

## Security and operations
- [ ] No secret keys or bank account numbers are committed to GitHub or frontend files.
- [ ] RLS policies protect bookings and personal contact details.
- [ ] Logs avoid storing full payment credentials or unnecessary personal data.
- [ ] Privacy notice, host terms, guest terms, cancellation/refund policy and commission terms are published.
- [ ] Monitoring, support contact, backup/restore and incident-response processes are ready.
- [ ] Written provider approval is received before switching from test to live keys.
