retry() {
    local attempt status
    for attempt in 1 2 3 4 5; do
        status=0
        "$@" || status=$?
        if [ $status -eq 0 ]; then
            return 0
        fi
        if [ $attempt -lt 5 ]; then
            echo "Attempt $attempt failed with exit code $status, retrying: $*" >&2
            sleep $((1 << attempt))
        fi
    done
    infra_error "'$*' failed after 5 attempts (exit code $status)."
    return $status
}

infra_error() {
    echo "::error title=CI infrastructure failure::$1 This is a network or package mirror problem, not caused by the tested change. Re-run the job."
}
