-- When a Moment happened, to the minute (docs/DESIGN-stellar-parity.md §6.9, §8.11.4): Publish's When takes a day and a
-- time, as Monad's does, and sends them as ISO 8601 with the creator's offset.
-- - moment_metadata.taken_on keeps the creator's calendar day, as every reader of a Moment's day has it; taken_at, beside
--   it, keeps the date and time as POST /v1/moments/metadata wrote it ("2026-10-14T18:30:00+02:00"), what the metadata's
--   Date attribute says. Null for a Moment published with a day alone.
-- - lite.moments gains the same column, for the indexer to copy with the rest of a Moment's metadata.
-- Additive: no existing row or reader changes.

alter table lite.moment_metadata add column if not exists taken_at text
  check (char_length(taken_at) <= 32 and taken_at ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$');

alter table lite.moments add column if not exists taken_at text
  check (char_length(taken_at) <= 32 and taken_at ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$');
