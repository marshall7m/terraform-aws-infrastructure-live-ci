UPDATE executions
SET
    approval_count = CASE WHEN "action" == 'approve' THEN approval_count + 1
    approval_voters = CASE 
        WHEN "action" == 'approve' THEN
            RAISE NOTICE 'Adding vote';
            add
        WHEN "action" == 'reject' THEN 
            RAISE NOTICE 'Updating vote';
            array_remove(approval_voters, recipient)
        ELSE 
            RAISE ...
    
    approval_voters = CASE 
        WHEN "action" == 'approve' THEN add
        WHEN "action" == 'reject' THEN array_remove(approval_voters, recipient)
        ELSE approval_voters
WHERE execution_id = _execution_id
RETURNING *;