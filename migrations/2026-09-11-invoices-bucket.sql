-- Private storage bucket for uploaded invoice PDFs (Participants tab archive)
-- Run manually in the Supabase SQL editor (project bhqjsqwbsbhjuhjwxwcp).
--
-- The app has always uploaded to a bucket named `invoices`, but the bucket was
-- never created. Every upload failed and fell back to storing the file as a
-- base64 data URL inside participants.invoice_files ("storage":"inline"). Those
-- inline files keep working after this runs; only new uploads go to storage.
--
-- PRIVATE, like tx-attachments: only the object path is stored, and
-- openInvoiceFile mints a 5-minute signed URL on demand. No permanent public
-- link to a participant's invoice ever exists.
--
-- Run this only AFTER the matching index.html change is deployed. The old code
-- stored getPublicUrl() links, which do not resolve on a private bucket.

insert into storage.buckets (id, name, public, file_size_limit)
values ('invoices', 'invoices', false, 5242880)   -- 5MB, matches the client-side cap
on conflict (id) do nothing;

-- The app uploads (upsert:false → insert), signs URLs (select) and removes files
-- from the archive (delete). No update: files are never overwritten in place.
create policy "invoices insert" on storage.objects
  for insert to authenticated with check (bucket_id = 'invoices');
create policy "invoices select" on storage.objects
  for select to authenticated using (bucket_id = 'invoices');
create policy "invoices delete" on storage.objects
  for delete to authenticated using (bucket_id = 'invoices');
