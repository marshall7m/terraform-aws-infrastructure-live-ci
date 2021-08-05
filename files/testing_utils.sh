assertEquals() {
    msg=$1 
    expected=$2
    actual=$3
    echo "$msg: "
    if [ "$expected" != "$actual" ]; then
        log "ASSERTION:FAILED EXPECTED=$expected ACTUAL=$actual" "ERROR"
    else
        echo "PASSED"
    fi
}

if [ -n "$MOCK_GIT_CMDS" ]; then
    source mock_git_cmds.sh
fi

if [ -n "$MOCK_AWS_CMDS" ]; then
    source mock_aws_cmds.sh
fi

