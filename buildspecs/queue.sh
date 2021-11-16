#!/bin/bash

set -e

pr_id=$(echo $CODEBUILD_SOURCE_VERSION | cut -d "/" -f 2)
log "Pull Request ID: ${pr_id}" "INFO"

base_ref=$(echo $CODEBUILD_WEBHOOK_BASE_REF | cut -d "/" -f 3)
log "Base Ref: ${base_ref}" "INFO"

head_ref=$(echo $CODEBUILD_WEBHOOK_HEAD_REF | cut -d "/" -f 3)
log "Head Ref: ${head_ref}" "INFO"

log "Commit ID: ${CODEBUILD_RESOLVED_SOURCE_VERSION}" "INFO"

log "Adding PR to pr_queue" "INFO"

psql -c  """
INSERT INTO pr_queue AS pr (
    pr_id,
    status,
    base_ref,
    head_ref
)
VALUES (
    '$pr_id',
    'waiting',
    '$base_ref,
    '$head_ref',
)
ON CONFLICT (pr_id) 
DO UPDATE SET 
    status = EXCLUDED.status,
    base_ref = EXCLUDED.base_ref,
    head_ref = EXCLUDED.head_ref
WHERE pr.status != 'running';
"""

log "Adding commit record to commit_queue" "INFO"

psql -c  """
INSERT INTO commit_queue(
    commit_id,
    pr_id,
    status,
    is_rollback,
    is_base_rollback
)
VALUES (
    '$CODEBUILD_RESOLVED_SOURCE_VERSION',
    '$pr_id',
    'waiting',
    false,
    false
)
WHERE 1 = (
    SELECT COUNT(*)
    FROM pr_queue
    WHERE pr_id = '$pr_id'
    AND status = 'running'
);
"""

set +e
