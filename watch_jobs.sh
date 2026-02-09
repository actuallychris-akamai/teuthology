#!/bin/bash
# watch_jobs.sh - Monitor teuthology job progress
# Usage: ./watch_jobs.sh [interval_seconds] [run_name]
#   interval_seconds: refresh interval (default: 30, 0 = single run)
#   run_name: specific run directory name, or "latest" (default: latest)

INTERVAL=${1:-30}
ARCHIVE_DIR="$HOME/.local/share/ceph-devstack/archive"

if [ -n "$2" ] && [ "$2" != "latest" ]; then
    RUN="$ARCHIVE_DIR/$2"
else
    RUN="$ARCHIVE_DIR/$(ls -t "$ARCHIVE_DIR" | head -1)"
fi

if [ ! -d "$RUN" ]; then
    echo "Run directory not found: $RUN"
    exit 1
fi

RUN_NAME=$(basename "$RUN")

count_matches() {
    local c
    c=$(grep -a -c "$@" 2>/dev/null) || true
    echo "${c:-0}"
}

# Truncate string to max length, adding .. if truncated
trunc() {
    local str="$1" max="$2"
    if [ "${#str}" -gt "$max" ]; then
        echo "${str:0:$((max-2))}.."
    else
        echo "$str"
    fi
}

# Extract all description fragments for a job
get_all_fragments() {
    local config="$1/config.yaml"
    [ ! -f "$config" ] && return
    local desc
    desc=$(sed -n '/^description:/,/^[^ ]/p' "$config" | grep -v '^[^ ]' | head -5)
    desc="$(grep '^description:' "$config" | head -1) $desc"
    echo "$desc" | tr '{}' ' ' | tr ' ' '\n' | grep '/' | sed 's|^[0-9]*-||' | sed 's|.*/||' | grep -v -E '^$'
}

# Build variant labels keeping only fragments that differ between jobs
build_variants() {
    local run_dir="$1"
    local -a all_jobs=()
    local -a all_frags=()
    for j in "$run_dir"/[0-9]*/; do
        [ ! -d "$j" ] && continue
        all_jobs+=("$j")
        all_frags+=("$(get_all_fragments "$j" | paste -sd'|' -)")
    done
    if [ "${#all_jobs[@]}" -eq 1 ]; then
        local frags
        frags=$(get_all_fragments "${all_jobs[0]}" | \
            grep -v -E '^(fixed-[0-9]+|install)$' | paste -sd',' -)
        VARIANTS["${all_jobs[0]}"]="${frags:--}"
        return
    fi
    for j in "${all_jobs[@]}"; do
        local my_frags unique=""
        my_frags=$(get_all_fragments "$j")
        while IFS= read -r frag; do
            [ -z "$frag" ] && continue
            local shared=true
            for other_frags in "${all_frags[@]}"; do
                if ! echo "$other_frags" | tr '|' '\n' | grep -qxF "$frag"; then
                    shared=false
                    break
                fi
            done
            if ! $shared; then
                unique="${unique:+$unique,}$frag"
            fi
        done <<< "$my_frags"
        VARIANTS["$j"]="${unique:--}"
    done
}

# Get testnode count and range from config.yaml targets
get_testnodes() {
    local config="$1/config.yaml"
    [ ! -f "$config" ] && return
    local nodes
    nodes=$(sed -n '/^targets:/,/^[^ ]/p' "$config" | grep -oP 'testnode-\K\d+' | sort -n)
    local count first last
    count=$(echo "$nodes" | wc -l)
    first=$(echo "$nodes" | head -1)
    last=$(echo "$nodes" | tail -1)
    if [ "$count" -eq 1 ]; then
        echo "$first"
    elif [ "$count" -eq $((last - first + 1)) ]; then
        echo "${first}..${last}"
    else
        echo "$nodes" | paste -sd',' -
    fi
}

# Get workunit progress: "N/total: script.sh"
get_workunit_status() {
    local log="$1" config="$2"
    local current num total
    current=$(grep -aoP 'Running workunits matching \K\S+' "$log" 2>/dev/null | tail -1)
    [ -z "$current" ] && return
    num=$(grep -acP 'Running workunits matching' "$log" 2>/dev/null)
    total=$(sed -n '/^- workunit:/,/^- [^ ]/p' "$config" 2>/dev/null | grep -cP '^\s+- ')
    [ "$total" -lt "$num" ] && total="$num"
    echo "[${num}/${total}: $(basename "$current")]"
}

# Get current phase when no tests are running yet
get_phase() {
    local log="$1"
    local task
    task=$(grep -aoP 'Running task \K\S+' "$log" 2>/dev/null | tail -1 | sed 's/\.\.\.$//')
    if [ -n "$task" ]; then
        echo "[$task]"
    elif grep -aq 'task.ansible' "$log" 2>/dev/null; then
        echo "[ansible]"
    else
        echo "[starting]"
    fi
}

# Query beanstalk for pending job counts
get_pending_jobs() {
    local stats
    stats=$(podman exec beanstalk sh -c "printf 'stats-tube testnode\r\n' | nc -w1 localhost 11300" 2>/dev/null) || return
    local ready buried reserved
    ready=$(echo "$stats" | grep -oP 'current-jobs-ready: \K\d+')
    buried=$(echo "$stats" | grep -oP 'current-jobs-buried: \K\d+')
    reserved=$(echo "$stats" | grep -oP 'current-jobs-reserved: \K\d+')
    echo "${ready:-0} ${reserved:-0} ${buried:-0}"
}

FMT="%-4s  %-40s  %-6s  %6s  %6s  %6s  %-s\n"

while true; do
    clear
    # Rebuild variants every cycle to pick up new jobs
    declare -A VARIANTS=()
    build_variants "$RUN"
    first_job=$(ls -d "$RUN"/[0-9]* 2>/dev/null | head -1)
    suite=$(grep '^suite:' "$first_job/config.yaml" 2>/dev/null | awk '{print $2}')
    branch=$(grep '^branch:' "$first_job/config.yaml" 2>/dev/null | awk '{print $2}')
    num_jobs=$(ls -d "$RUN"/[0-9]* 2>/dev/null | wc -l)

    # Query beanstalk for pending jobs
    pending_info=$(get_pending_jobs)
    pending_ready=$(echo "$pending_info" | awk '{print $1}')
    pending_reserved=$(echo "$pending_info" | awk '{print $2}')
    pending_buried=$(echo "$pending_info" | awk '{print $3}')

    echo "=== $suite ($branch) — $(date +%H:%M:%S) ==="
    echo "Run: $RUN_NAME"
    queue_str="Jobs: $num_jobs dispatched"
    if [ -n "$pending_ready" ] && [ "$pending_ready" -gt 0 ] 2>/dev/null; then
        queue_str="$queue_str, $pending_ready queued"
    fi
    if [ -n "$pending_reserved" ] && [ "$pending_reserved" -gt 0 ] 2>/dev/null; then
        queue_str="$queue_str, $pending_reserved dispatching"
    fi
    if [ -n "$pending_buried" ] && [ "$pending_buried" -gt 0 ] 2>/dev/null; then
        queue_str="$queue_str, $pending_buried buried"
    fi
    echo "$queue_str"
    echo ""

    printf "$FMT" "Job" "Variant" "Nodes" "Passed" "Failed" "Errors" "Status"
    printf "$FMT" "---" "-------" "-----" "------" "------" "------" "------"

    total_passed=0
    total_failed=0
    total_errors=0
    all_done=true
    any_failure=false

    for j in "$RUN"/[0-9]*/; do
        [ ! -d "$j" ] && continue
        job=$(basename "$j")
        variant=$(trunc "${VARIANTS[$j]:--}" 40)
        testnodes=$(get_testnodes "$j")
        log="$j/teuthology.log"

        if [ -f "$j/summary.yaml" ]; then
            succ=$(grep -aoP 'success: \K.*' "$j/summary.yaml")
            py_pass=$(count_matches -aP '::\S+ PASSED' "$log")
            py_fail=$(count_matches -aP '::\S+ FAILED' "$log")
            gt_ok=$(count_matches -aP '\[\s+OK \]' "$log")
            gt_fail=$(count_matches -aP '\[\s+FAILED\s+\]' "$log")
            passed=$((py_pass + gt_ok))
            failed=$((py_fail + gt_fail))
            errors=$(count_matches -aP '::\S+ ERROR' "$log")
            total_passed=$((total_passed + passed))
            total_failed=$((total_failed + failed))
            total_errors=$((total_errors + errors))
            if [ "$succ" = "true" ]; then
                if [ "$passed" -gt 0 ]; then
                    status="PASS ($passed passed)"
                else
                    status="PASS"
                fi
            else
                status="FAIL"
                any_failure=true
            fi
            printf "$FMT" "$job" "$variant" "$testnodes" "$passed" "$failed" "$errors" "$status"
        elif [ -f "$log" ]; then
            all_done=false
            # Count all test styles
            py_pass=$(count_matches -aP '::\S+ PASSED' "$log")
            py_fail=$(count_matches -aP '::\S+ FAILED' "$log")
            errors=$(count_matches -aP '::\S+ ERROR' "$log")
            gt_ok=$(count_matches -aP '\[\s+OK \]' "$log")
            gt_fail=$(count_matches -aP '\[\s+FAILED\s+\]' "$log")
            passed=$((py_pass + gt_ok))
            failed=$((py_fail + gt_fail))
            if [ "$passed" -gt 0 ] || [ "$failed" -gt 0 ] || [ "$errors" -gt 0 ]; then
                # Show current workunit if running, else last test name
                wu=$(grep -aoP 'Running workunits matching \K\S+' "$log" 2>/dev/null | tail -1)
                last=$(grep -aoP '::\K\S+(?= (PASSED|FAILED|ERROR))' "$log" 2>/dev/null | tail -1)
                if [ -z "$last" ]; then
                    last=$(grep -aoP '\[ RUN      \] \K\S+' "$log" 2>/dev/null | tail -1)
                fi
                # If current workunit differs from what produced the last test, show it
                if [ -n "$wu" ] && [ -n "$last" ]; then
                    wu_base=$(basename "$wu" .sh)
                    if ! echo "$last" | grep -qi "${wu_base%%_*}"; then
                        last=$(get_workunit_status "$log" "$j/config.yaml")
                    fi
                fi
                # Append s3test progress percentage if available
                pct=$(tail -500 "$log" 2>/dev/null | grep -aoP '\[\s*\K\d+%' | tail -1)
                if [ -n "$pct" ]; then
                    status=$(trunc "${last:-[testing]}" 34)
                    status="$status ($pct)"
                else
                    status=$(trunc "${last:-[testing]}" 40)
                fi
            else
                # No test output yet — show workunit name or phase
                wu_status=$(get_workunit_status "$log" "$j/config.yaml")
                if [ -n "$wu_status" ]; then
                    status="$wu_status"
                else
                    status=$(get_phase "$log")
                fi
            fi
            total_passed=$((total_passed + passed))
            total_failed=$((total_failed + failed))
            total_errors=$((total_errors + errors))
            printf "$FMT" "$job" "$variant" "$testnodes" "$passed" "$failed" "$errors" "$status"
        else
            all_done=false
            printf "$FMT" "$job" "$variant" "$testnodes" "-" "-" "-" "[waiting]"
        fi
    done

    echo ""
    printf "Totals: %d passed, %d failed, %d errors\n" "$total_passed" "$total_failed" "$total_errors"

    # Check if there are still pending jobs in beanstalk
    jobs_pending=false
    if [ -n "$pending_ready" ] && [ "$pending_ready" -gt 0 ] 2>/dev/null; then
        jobs_pending=true
    fi
    if [ -n "$pending_reserved" ] && [ "$pending_reserved" -gt 0 ] 2>/dev/null; then
        jobs_pending=true
    fi
    if [ -n "$pending_buried" ] && [ "$pending_buried" -gt 0 ] 2>/dev/null; then
        jobs_pending=true
    fi

    if $all_done && ! $jobs_pending; then
        echo ""
        if $any_failure; then
            echo "RESULT: Some jobs FAILED"
            echo ""
            echo "Failed jobs:"
            for j in "$RUN"/[0-9]*/; do
                [ ! -f "$j/summary.yaml" ] && continue
                succ=$(grep -aoP 'success: \K.*' "$j/summary.yaml")
                if [ "$succ" != "true" ]; then
                    job=$(basename "$j")
                    variant="${VARIANTS[$j]:--}"
                    failure=$(grep -aoP 'failure_reason: \K.*' "$j/summary.yaml")
                    echo "  Job $job ($variant): $failure"
                fi
            done
        else
            echo "RESULT: All jobs PASSED"
        fi
        echo ""
        if [ "$total_failed" -gt 0 ] || [ "$total_errors" -gt 0 ]; then
            echo "Test failures/errors:"
            for j in "$RUN"/[0-9]*/; do
                job=$(basename "$j")
                grep -aoP '::\K\S+ (FAILED|ERROR)' "$j/teuthology.log" 2>/dev/null | while read -r line; do
                    echo "  Job $job: $line"
                done
            done
        fi
        break
    elif $all_done && $jobs_pending; then
        echo ""
        echo "All dispatched jobs done. Waiting for $pending_ready queued + $pending_buried buried jobs..."
    fi

    [ "$INTERVAL" -eq 0 ] && break
    sleep "$INTERVAL"
done
