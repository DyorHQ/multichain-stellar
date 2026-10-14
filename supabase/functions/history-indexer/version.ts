// The indexer's version, recorded in every history_indexer_runs row (history_lease checks ^[0-9A-Za-z._-]{1,40}$).
// DEPLOY: in the copy uploaded to Supabase, replace the placeholder below with the deployed commit's short SHA
// (`git rev-parse --short HEAD`), so a deploy or a rollback can be confirmed from the run rows. The repository keeps the
// placeholder; a run reporting it was deployed without that step.
export const VERSION = "__DEPLOY_SHA__";
