DROP INDEX IF EXISTS account_deletion_requests_receipt_hash_idx;

ALTER TABLE account_deletion_requests
    DROP COLUMN IF EXISTS deletion_receipt_hash;
