-- noqa: disable=PRS
UPDATE executions
SET
    approval_voters = CASE
        WHEN '{action}' = 'approve' THEN
            (
                SELECT array_agg(DISTINCT e)
                FROM unnest(approval_voters || ARRAY['{recipient}']) e
            )
        WHEN '{action}' = 'reject' THEN
            array_remove(approval_voters, '{recipient}')
    END,
    rejection_voters = CASE
        WHEN '{action}' = 'approve' THEN
            array_remove(rejection_voters, '{recipient}')
        WHEN '{action}' = 'reject' THEN
            (
                SELECT array_agg(DISTINCT e)
                FROM unnest(rejection_voters || ARRAY['{recipient}']) e
            )
    END
WHERE execution_id = '{execution_id}'
RETURNING "status", approval_voters, min_approval_count, rejection_voters, min_rejection_count;
