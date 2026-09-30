ALTER TABLE account_deletion_requests
    ADD COLUMN deletion_receipt_hash CHAR(64);

CREATE UNIQUE INDEX account_deletion_requests_receipt_hash_idx
    ON account_deletion_requests(deletion_receipt_hash)
    WHERE deletion_receipt_hash IS NOT NULL;
