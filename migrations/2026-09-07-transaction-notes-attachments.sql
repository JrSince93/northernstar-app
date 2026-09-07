-- Notes and receipt images on cash book transactions (Expenses tab)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- Set from the "Allocate expense" modal when allocating a SINGLE transaction.
-- A bulk allocation hides these fields, since one note or receipt cannot
-- sensibly describe several different transactions.
--
-- STORAGE: this SQL is not enough on its own. A bucket named `tx-attachments`
-- must also be created (Storage -> New bucket in the Supabase dashboard), and
-- it must be PRIVATE. Receipts are read through short-lived signed URLs minted
-- on demand (createSignedUrl, 1 hour), so no permanent public link to a
-- participant's receipt ever exists. Only attachment_path is persisted; there
-- is deliberately no attachment_url column, because a signed URL expires and
-- storing one would just go stale.
--
-- A private bucket needs a storage RLS policy allowing the signed-in app user
-- to read and write objects in it — an authenticated-role policy on
-- storage.objects scoped to bucket_id = 'tx-attachments'. Without one, uploads
-- and signed-URL requests are rejected.
--
-- Nothing in the app executes this. Until it runs, allocation still succeeds
-- and only the note/receipt write fails, with a toast saying so.

alter table public.transactions
  add column if not exists note            text,
  add column if not exists attachment_path text;

comment on column public.transactions.note is
  'Free-text note recorded when the transaction was allocated. Expenses tab only.';
comment on column public.transactions.attachment_path is
  'Storage path inside the private tx-attachments bucket. Read via a short-lived signed URL; also what lets the object be deleted later.';
