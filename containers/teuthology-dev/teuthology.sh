#!/usr/bin/bash
set -e
source /teuthology/virtualenv/bin/activate
set -x
cat /run/secrets/id_rsa > $HOME/.ssh/id_rsa
if [ -n "$TEUTHOLOGY_TESTNODES" ]; then
    for node in $(echo $TEUTHOLOGY_TESTNODES | tr , ' '); do
        teuthology-update-inventory -m "$TEUTHOLOGY_MACHINE_TYPE" "$node"
    done
    TEUTHOLOGY_CONF=${TEUTHOLOGY_CONF:-}
else
    TEUTHOLOGY_CONF=${TEUTHOLOGY_CONF:-/teuthology/containerized_node.yaml}
fi
export TEUTHOLOGY_MACHINE_TYPE=${TEUTHOLOGY_MACHINE_TYPE:-testnode}
if [ "$TEUTHOLOGY_SUITE" != "none" ]; then
    if [ -n "$TEUTHOLOGY_BRANCH" ]; then
      TEUTH_BRANCH_FLAG="--teuthology-branch $TEUTHOLOGY_BRANCH"
    fi

    # Merge default and user-provided filter-out values into a single flag.
    DEFAULT_FILTER_OUT="${TEUTHOLOGY_DEFAULT_FILTER_OUT:-libcephfs,kclient,valgrind,cls_sem_set}"
    EXTRA_ARGS_RAW="${TEUTHOLOGY_SUITE_EXTRA_ARGS:-}"
    EXTRA_ARGS_NO_FILTER_OUT=()
    EXTRA_FILTER_OUT=""

    if [ -n "$EXTRA_ARGS_RAW" ]; then
        read -r -a EXTRA_ARGS_ARR <<< "$EXTRA_ARGS_RAW"
        i=0
        while [ $i -lt ${#EXTRA_ARGS_ARR[@]} ]; do
            arg="${EXTRA_ARGS_ARR[$i]}"
            if [ "$arg" = "--filter-out" ]; then
                i=$((i + 1))
                if [ $i -lt ${#EXTRA_ARGS_ARR[@]} ]; then
                    if [ -n "$EXTRA_FILTER_OUT" ]; then
                        EXTRA_FILTER_OUT="$EXTRA_FILTER_OUT,${EXTRA_ARGS_ARR[$i]}"
                    else
                        EXTRA_FILTER_OUT="${EXTRA_ARGS_ARR[$i]}"
                    fi
                fi
            elif [[ "$arg" == --filter-out=* ]]; then
                value="${arg#--filter-out=}"
                if [ -n "$value" ]; then
                    if [ -n "$EXTRA_FILTER_OUT" ]; then
                        EXTRA_FILTER_OUT="$EXTRA_FILTER_OUT,$value"
                    else
                        EXTRA_FILTER_OUT="$value"
                    fi
                fi
            else
                EXTRA_ARGS_NO_FILTER_OUT+=("$arg")
            fi
            i=$((i + 1))
        done
    fi

    MERGED_FILTER_OUT="$DEFAULT_FILTER_OUT"
    if [ -n "$EXTRA_FILTER_OUT" ]; then
        MERGED_FILTER_OUT="$MERGED_FILTER_OUT,$EXTRA_FILTER_OUT"
    fi

    FILTER_OUT_FINAL=""
    OLD_IFS="$IFS"
    IFS=','
    for raw_keyword in $MERGED_FILTER_OUT; do
        keyword="${raw_keyword#"${raw_keyword%%[![:space:]]*}"}"
        keyword="${keyword%"${keyword##*[![:space:]]}"}"
        if [ -z "$keyword" ]; then
            continue
        fi
        case ",$FILTER_OUT_FINAL," in
            *",$keyword,"*) ;;
            *)
                if [ -n "$FILTER_OUT_FINAL" ]; then
                    FILTER_OUT_FINAL="$FILTER_OUT_FINAL,$keyword"
                else
                    FILTER_OUT_FINAL="$keyword"
                fi
                ;;
        esac
    done
    IFS="$OLD_IFS"

    FILTER_OUT_ARGS=()
    if [ -n "$FILTER_OUT_FINAL" ]; then
        FILTER_OUT_ARGS=(--filter-out "$FILTER_OUT_FINAL")
    fi

    teuthology-suite -v \
        $TEUTH_BRANCH_FLAG \
        -m "$TEUTHOLOGY_MACHINE_TYPE" \
        --newest 100 \
        --ceph "${TEUTHOLOGY_CEPH_BRANCH:-main}" \
        --ceph-repo "${TEUTHOLOGY_CEPH_REPO:-https://github.com/ceph/ceph.git}" \
        --suite "${TEUTHOLOGY_SUITE:-teuthology:no-ceph}" \
        --suite-branch "${TEUTHOLOGY_SUITE_BRANCH:-main}" \
        --suite-repo "${TEUTHOLOGY_SUITE_REPO:-https://github.com/ceph/ceph.git}" \
        "${FILTER_OUT_ARGS[@]}" \
        --force-priority \
        --seed 349 \
        "${EXTRA_ARGS_NO_FILTER_OUT[@]}" \
        $TEUTHOLOGY_CONF
    DISPATCHER_EXIT_FLAG='--exit-on-empty-queue'
    teuthology-queue -m $TEUTHOLOGY_MACHINE_TYPE -s | \
      python3 -c "import sys, json; assert json.loads(sys.stdin.read())['count'] > 0, 'queue is empty!'"
fi
teuthology-dispatcher -v \
    --log-dir /teuthology/log \
    --tube "$TEUTHOLOGY_MACHINE_TYPE" \
    $DISPATCHER_EXIT_FLAG
