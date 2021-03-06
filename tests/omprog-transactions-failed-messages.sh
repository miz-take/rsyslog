#!/bin/bash
# This file is part of the rsyslog project, released under ASL 2.0

echo ===============================================================================
echo '[omprog-transactions-failed-messages.sh]: test omprog with confirmMessages and useTransactions flags enabled, with message failures'

. $srcdir/diag.sh init
. $srcdir/diag.sh startup omprog-transactions-failed-messages.conf
. $srcdir/diag.sh wait-startup

. $srcdir/diag.sh injectmsg 0 10

. $srcdir/diag.sh wait-queueempty
. $srcdir/diag.sh shutdown-when-empty
. $srcdir/diag.sh wait-shutdown

# Since the transaction boundaries are not deterministic, we cannot check for
# an exact expected output. We must check the output programmatically.

transaction_state="NONE"
status_expected=true
messages_to_commit=()
messages_processed=()
line_num=1
error=

while IFS= read -r line; do
    if [[ $status_expected == true ]]; then
        case "$transaction_state" in
        "NONE")
            if [[ "$line" != "<= OK" ]]; then
                error="expecting an OK status from script"
                break
            fi
            ;;
        "STARTED")
            if [[ "$line" != "<= OK" ]]; then
                error="expecting an OK status from script"
                break
            fi
            transaction_state="ACTIVE"
            ;;
        "ACTIVE")
            if [[ "$line" == "<= Error: could not process log message" ]]; then
                #
                # TODO: Issue #2420: Deferred messages within a transaction are
                # not retried by rsyslog.
                # If that's the expected behaviour, what's then the difference
                # between the RS_RET_OK and the RS_RET_DEFER_COMMIT return codes?
                # If that's not the expected behaviour, the following lines must
                # be removed when the bug is solved.
                #
                # (START OF CODE THAT WILL POSSIBLY NEED TO BE REMOVED)
                messages_processed+=("${messages_to_commit[@]}")
                unset "messages_processed[${#messages_processed[@]}-1]"
                # (END OF CODE THAT WILL POSSIBLY NEED TO BE REMOVED)

                messages_to_commit=()
                transaction_state="NONE"
            elif [[ "$line" != "<= DEFER_COMMIT" ]]; then
                error="expecting a DEFER_COMMIT status from script"
                break
            fi
            ;;
        "COMMITTED")
            if [[ "$line" != "<= OK" ]]; then
                error="expecting an OK status from script"
                break
            fi
            messages_processed+=("${messages_to_commit[@]}")
            messages_to_commit=()
            transaction_state="NONE"
            ;;
        esac
        status_expected=false;
    else
        if [[ "$line" == "=> BEGIN TRANSACTION" ]]; then
            if [[ "$transaction_state" != "NONE" ]]; then
                error="unexpected transaction start"
                break
            fi
            transaction_state="STARTED"
        elif [[ "$line" == "=> COMMIT TRANSACTION" ]]; then
            if [[ "$transaction_state" != "ACTIVE" ]]; then
                error="unexpected transaction commit"
                break
            fi
            transaction_state="COMMITTED"
        else
            if [[ "$transaction_state" != "ACTIVE" ]]; then
                error="unexpected message outside a transaction"
                break
            fi
            if [[ "$line" != "=> msgnum:"* ]]; then
                error="unexpected message contents"
                break
            fi
            prefix_to_remove="=> "
            messages_to_commit+=("${line#$prefix_to_remove}")
        fi
        status_expected=true;
    fi
    let "line_num++"
done < rsyslog.out.log

if [[ -z "$error" && "$transaction_state" != "NONE" ]]; then
    error="unexpected end of file (transaction state: $transaction_state)"
fi

if [[ -n "$error" ]]; then
    echo "rsyslog.out.log: line $line_num: $error"
    cat rsyslog.out.log
    . $srcdir/diag.sh error-exit 1
fi

# Since the order in which failed messages are retried by rsyslog is not
# deterministic, we sort the processed messages before checking them.
IFS=$'\n' messages_sorted=($(sort <<<"${messages_processed[*]}"))
unset IFS

expected_messages=(
    "msgnum:00000000:"
    "msgnum:00000001:"
    "msgnum:00000002:"
    "msgnum:00000003:"
    "msgnum:00000004:"
    "msgnum:00000005:"
    "msgnum:00000006:"
    "msgnum:00000007:"
    "msgnum:00000008:"
    "msgnum:00000009:"
)
if [[ "${messages_sorted[*]}" != "${expected_messages[*]}" ]]; then
    echo "unexpected set of processed messages:"
    printf '%s\n' "${messages_processed[@]}"
    echo "contents of rsyslog.out.log:"
    cat rsyslog.out.log
    . $srcdir/diag.sh error-exit 1
fi

. $srcdir/diag.sh exit
