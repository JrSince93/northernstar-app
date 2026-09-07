-- Notes and receipt images on cash book transactions (Expenses tab)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- Set from the "Allocate expense" modal when allocating a SINGLE transaction.
-- A bulk allocation hides these fields, since one note or receipt cannot
-- sensibly describe several different transactions.
--
-- STORAGE: this SQL is not enough on its own. A bucket named `tx-attachments`
-- must also be created (Storage -> New bucket in the Supabase dashboard).
-- getPublicUrl() only returns a working link if that bucket is public, which is
-- how the existing `invoices` bucket is set up.
--
-- PRIVACY: a public bucket means anyone holding the URL can view the receipt
-- with no login. These are participants' expense receipts and may show names,
-- addresses or health-related purchases. The URLs are unguessable but not
-- access-controlled. A private bucket with signed URLs is the alternative if
-- that trade-off isn't wanted — it would need the read path changed to
-- createSignedUrl().
--
-- Nothing in the app executes this. Until it runs, allocation still succeeds
-- and only the note/receipt write fails, with a toast saying so.

alter table public.transactions
  add column if not exists note            text,
  add column if not exists attachment_url  text,
  add column if not exists attachment_path text;

comment on column public.transactions.note is
  'Free-text note recorded when the transaction was allocated. Expenses tab only.';
comment on column public.transactions.attachment_url is
  'Public URL of the receipt image in the tx-attachments bucket.';
comment on column public.transactions.attachment_path is
  'Storage path inside tx-attachments, kept alongside the URL so the object can be deleted later.';
