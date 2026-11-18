#!/usr/bin/env bash
set -euo pipefail

# Tvheadend MPEG-TS DTS wrap and legacy PTS_UNSET estimator.
#
# Briefly tune each channel in turn, then run this script to compare the
# projected wrap and PTS_UNSET times for every channel and elementary stream
# found in the lookback window.
#
# Requirements:
# - Linux with journalctl, GNU date and awk.
# - Enable Tvheadend's tsfix trace (Debug all) while tuning each channel.
# - Keep only one channel subscription active at a time so trace records can
#   be associated with the correct channel.
#
# Usage:
#   ./tvh_calc_dts_wrap_pts_unset_short.sh
#   LOOKBACK="1 hours ago" ./tvh_calc_dts_wrap_pts_unset_short.sh
#
# Each estimate is projected from that stream's latest trace sample. It is not
# a guaranteed wall-clock time: retunes, discontinuities, reference changes or
# changes in media-clock rate can move the actual boundary.

TVH_UNIT="${TVH_UNIT:-tvheadend}"
LOOKBACK="${LOOKBACK:-24 hours ago}"
JOURNAL_FILTER='subscribing on channel|unsubscribing from|tsfix: deliver'

PTS_MODULO=8589934592
PTS_MASK=8589934591
CLOCK_HZ=90000
PTS_QUARTER=$((PTS_MASK / 4))
PTS_HALF=$((PTS_MASK / 2))
NOW_EPOCH=$(date +%s)

# Track sequential subscription sessions. A tsfix record does not identify its
# channel, so accept it only when exactly one subscription is active. Retain
# the latest session/sample for each channel and elementary stream.
PARSED_WITH_STATUS=$(
    set +e
    sudo journalctl -u "$TVH_UNIT" --since "$LOOKBACK" --no-pager \
        --output=short-iso-precise --grep="$JOURNAL_FILTER" | awk '
function get_subscription_id(line, token) {
    if (!match(line, /subscription: [[:xdigit:]]+:/))
        return ""
    token = substr(line, RSTART, RLENGTH)
    sub(/^subscription: /, "", token)
    sub(/:$/, "", token)
    return token
}

function get_channel_name(line, token) {
    if (!match(line, /subscribing on channel "[^"]+"/))
        return ""
    token = substr(line, RSTART, RLENGTH)
    sub(/^subscribing on channel "/, "", token)
    sub(/"$/, "", token)
    return token
}

function active_count(sid, count) {
    count = 0
    for (sid in active_session)
        count++
    return count
}

function legacy_pts_diff_is_unset(a, b) {
    return (b < a && !(b < 2147483647 && a > 4294967295))
}

{
    timestamp = $1

    if ($0 ~ /subscribing on channel "/) {
        sid = get_subscription_id($0)
        channel = get_channel_name($0)
        if (sid != "" && channel != "") {
            session_number++
            active_session[sid] = session_number
            session_channel[session_number] = channel
            next
        }
    }

    if ($0 ~ /unsubscribing from/) {
        sid = get_subscription_id($0)
        if (sid != "" && (sid in active_session))
            delete active_session[sid]
        next
    }

    if ($0 !~ /tsfix: deliver/)
        next

    if (!match($0, /odts -?[0-9]+/))
        next
    odts_text = substr($0, RSTART, RLENGTH)
    sub(/^odts /, "", odts_text)

    if (!match($0, /ref -?[0-9]+/))
        next
    ref_text = substr($0, RSTART, RLENGTH)
    sub(/^ref /, "", ref_text)

    if (!match($0, /epoch -?[0-9]+/))
        next
    epoch_text = substr($0, RSTART, RLENGTH)
    sub(/^epoch /, "", epoch_text)

    if (!match($0, / dts -?[0-9]+/))
        next
    dts_text = substr($0, RSTART, RLENGTH)
    sub(/^ dts /, "", dts_text)

    if (!match($0, /pkt stream [0-9]+ [[:alnum:]_+-]+/))
        next
    stream_text = substr($0, RSTART, RLENGTH)
    sub(/^pkt stream /, "", stream_text)
    split(stream_text, stream_fields, /[[:space:]]+/)
    stream_index = stream_fields[1]
    stream_type = stream_fields[2]

    if ((odts_text + 0) < 0 || (ref_text + 0) < 0 || (dts_text + 0) < 0)
        next

    if (active_count() != 1)
        next
    for (sid in active_session)
        session = active_session[sid]

    ref_value = (ref_text + 0) % 8589934592
    odts_value = (odts_text + 0) % 8589934592
    # Reconstruct the input to the original pts_diff(): (ref + dts - epoch) mod 2^33.
    effective_value = (ref_value + (dts_text + 0) - (epoch_text + 0)) % 8589934592
    if (effective_value < 0)
        effective_value += 8589934592

    key = session SUBSEP stream_index SUBSEP stream_type
    if (!(key in sample_count)) {
        first_timestamp[key] = timestamp
        first_effective[key] = effective_value
        first_ref[key] = ref_value
        first_odts[key] = odts_value
        first_invalid[key] = legacy_pts_diff_is_unset(ref_value, effective_value)
        legacy_failure_timestamp[key] = "NONE"
        ref_changed[key] = 0
        key_session[key] = session
        key_stream_index[key] = stream_index
        key_stream_type[key] = stream_type
    } else {
        if (ref_value != first_ref[key])
            ref_changed[key] = 1

        boundary_crossed = 0
        if (legacy_failure_timestamp[key] == "NONE" &&
            !first_invalid[key] && ref_value == first_ref[key] &&
            legacy_pts_diff_is_unset(ref_value, effective_value)) {
            if (ref_value > 4294967295) {
                boundary_crossed = (last_effective[key] < 2147483647 &&
                                    effective_value >= 2147483647 &&
                                    effective_value < ref_value)
            } else if (ref_value > 0) {
                boundary_crossed = (last_effective[key] > 4294967295 &&
                                    effective_value < ref_value)
            }
            if (boundary_crossed)
                legacy_failure_timestamp[key] = timestamp
        }
    }

    last_timestamp[key] = timestamp
    last_effective[key] = effective_value
    last_ref[key] = ref_value
    last_odts[key] = odts_value
    last_epoch[key] = epoch_text
    last_dts[key] = dts_text
    sample_count[key]++
    sample_order[key] = ++total_samples
}

END {
    for (key in sample_count) {
        session = key_session[key]
        group = session_channel[session] SUBSEP key_stream_index[key] SUBSEP key_stream_type[key]
        if (!(group in latest_key) || sample_order[key] > latest_order[group]) {
            latest_key[group] = key
            latest_order[group] = sample_order[key]
        }
    }

    for (group in latest_key) {
        key = latest_key[group]
        session = key_session[key]
        failure_ts = legacy_failure_timestamp[key]
        if (failure_ts == "")
            failure_ts = "NONE"
        printf "DATA\034%s\034%s\034%s\034%.0f\034%.0f\034%.0f\034%.0f\034%s\034%s\034%.0f\034%.0f\034%.0f\034%s\034%s\034%d\034%d\034%s\n", \
            session_channel[session], key_stream_index[key], key_stream_type[key], \
            first_effective[key], first_ref[key], first_odts[key], first_invalid[key], \
            first_timestamp[key], last_timestamp[key], last_effective[key], \
            last_ref[key], last_odts[key], last_epoch[key], last_dts[key], \
            sample_count[key], ref_changed[key], failure_ts
    }
}
'
    PIPE_STATUS=("${PIPESTATUS[@]}")
    printf '\035%s\t%s' "${PIPE_STATUS[0]:-1}" "${PIPE_STATUS[1]:-1}"
)

PIPE_STATUS_TEXT="${PARSED_WITH_STATUS##*$'\035'}"
PARSED_DATA="${PARSED_WITH_STATUS%$'\035'*}"
IFS=$'\t' read -r JOURNAL_RC AWK_RC <<< "$PIPE_STATUS_TEXT"

if (( JOURNAL_RC != 0 )); then
    echo "ERROR: Could not read/filter the Tvheadend journal." >&2
    echo "Check the unit name, journal permissions and journalctl --grep support." >&2
    exit 1
fi
if (( AWK_RC != 0 )); then
    echo "ERROR: Failed to parse Tvheadend journal records (awk exit $AWK_RC)." >&2
    exit 1
fi

if [[ -z "$PARSED_DATA" ]]; then
    echo "ERROR: No usable tsfix samples could be associated with a channel." >&2
    echo "Ensure each subscription start is in LOOKBACK and only one channel is active at a time." >&2
    exit 1
fi

format_timestamp() {
    date -d "@$1" '+%d.%m.%Y %H:%M:%S %Z'
}

projection_seconds() {
    local ticks="$1"
    local nanoseconds="$2"
    local numerator denominator

    # Round up to a whole second so the displayed time is not before the boundary.
    numerator=$((ticks * 1000000000 + nanoseconds * CLOCK_HZ))
    denominator=$((CLOCK_HZ * 1000000000))
    printf '%s' "$(((numerator + denominator - 1) / denominator))"
}

legacy_failure_ticks_remaining() {
    local dts="$1"
    local ref="$2"

    # Mirror the original pts_diff() conditions, including their strict bounds.
    if (( ref == 0 )); then
        printf '%s' '-1'
    elif (( ref > PTS_HALF )); then
        if (( dts >= ref )); then
            printf '%s' "$((PTS_MODULO - dts + PTS_QUARTER))"
        elif (( dts < PTS_QUARTER )); then
            printf '%s' "$((PTS_QUARTER - dts))"
        else
            printf '%s' '0'
        fi
    elif (( dts >= ref )); then
        printf '%s' "$((PTS_MODULO - dts))"
    else
        printf '%s' '0'
    fi
}

DETAIL_ROWS=""
while IFS=$'\034' read -r KIND CHANNEL STREAM_INDEX STREAM_TYPE FIRST_INPUT FIRST_REF FIRST_ODTS \
    FIRST_INVALID FIRST_TS LAST_TS LAST_INPUT LAST_REF LAST_ODTS LAST_EPOCH LAST_DTS \
    SAMPLE_COUNT REF_CHANGED OBSERVED_FAILURE; do
    [[ "$KIND" == "DATA" ]] || continue

    for VALUE in "$FIRST_INPUT" "$FIRST_REF" "$FIRST_ODTS" "$LAST_INPUT" "$LAST_REF" \
        "$LAST_ODTS" "$LAST_EPOCH" "$LAST_DTS"; do
        if ! [[ "$VALUE" =~ ^-?[0-9]+$ ]]; then
            echo "WARNING: Invalid numeric trace value for $CHANNEL / $STREAM_TYPE; skipping row." >&2
            continue 2
        fi
    done
    if ! [[ "$FIRST_INPUT" =~ ^[0-9]+$ && "$FIRST_REF" =~ ^[0-9]+$ &&
            "$FIRST_ODTS" =~ ^[0-9]+$ &&
            "$LAST_INPUT" =~ ^[0-9]+$ && "$LAST_REF" =~ ^[0-9]+$ &&
            "$LAST_ODTS" =~ ^[0-9]+$ && "$LAST_DTS" =~ ^[0-9]+$ ]]; then
        echo "WARNING: Negative or invalid timestamp value for $CHANNEL / $STREAM_TYPE; skipping row." >&2
        continue
    fi

    if ! LAST_SAMPLE_EPOCH=$(date -d "$LAST_TS" +%s); then
        echo "WARNING: Invalid log timestamp '$LAST_TS' for $CHANNEL / $STREAM_TYPE; skipping row." >&2
        continue
    fi
    if ! LAST_SAMPLE_NANO=$(date -d "$LAST_TS" +%N); then
        echo "WARNING: Could not read timestamp precision for $CHANNEL / $STREAM_TYPE; skipping row." >&2
        continue
    fi
    LAST_SAMPLE_NANO=$((10#$LAST_SAMPLE_NANO))

    FIRST_INPUT=$((10#$FIRST_INPUT % PTS_MODULO))
    FIRST_REF=$((10#$FIRST_REF % PTS_MODULO))
    FIRST_ODTS=$((10#$FIRST_ODTS % PTS_MODULO))
    LAST_INPUT=$((10#$LAST_INPUT % PTS_MODULO))
    LAST_REF=$((10#$LAST_REF % PTS_MODULO))
    LAST_ODTS=$((10#$LAST_ODTS % PTS_MODULO))

    WRAP_TICKS=$((PTS_MODULO - LAST_INPUT))
    WRAP_SEC=$(projection_seconds "$WRAP_TICKS" "$LAST_SAMPLE_NANO")
    NEXT_WRAP_EPOCH=$((LAST_SAMPLE_EPOCH + WRAP_SEC))
    NEXT_WRAP_FMT=$(format_timestamp "$NEXT_WRAP_EPOCH")

    if (( REF_CHANGED == 1 || FIRST_REF != LAST_REF )); then
        PTS_LABEL="n/a"
        PTS_TICKS="n/a"
        SORT_KEY="$NEXT_WRAP_EPOCH"
        STATUS="ref changed"
    elif [[ "$FIRST_INVALID" == "1" ]]; then
        PTS_LABEL="already invalid at first sample"
        PTS_TICKS="n/a"
        SORT_KEY=0
        STATUS="invalid at start"
    elif [[ "$OBSERVED_FAILURE" != "NONE" ]]; then
        if OBSERVED_EPOCH=$(date -d "$OBSERVED_FAILURE" +%s); then
            PTS_LABEL="$(format_timestamp "$OBSERVED_EPOCH")"
            PTS_TICKS="0"
            SORT_KEY="$OBSERVED_EPOCH"
            STATUS="observed"
        else
            PTS_LABEL="n/a"
            PTS_TICKS="0"
            SORT_KEY=0
            STATUS="observed; bad time"
        fi
    else
        PTS_TICKS=$(legacy_failure_ticks_remaining "$LAST_INPUT" "$LAST_REF")
        if (( PTS_TICKS == -1 )); then
            PTS_LABEL="not expected (ref=0)"
            PTS_TICKS="n/a"
            SORT_KEY="$NEXT_WRAP_EPOCH"
            STATUS="not expected"
        elif (( PTS_TICKS == 0 )); then
            PTS_LABEL="already in failure region"
            SORT_KEY=0
            STATUS="already in region"
        else
            PTS_SEC=$(projection_seconds "$PTS_TICKS" "$LAST_SAMPLE_NANO")
            PTS_EPOCH=$((LAST_SAMPLE_EPOCH + PTS_SEC))
            PTS_LABEL=$(format_timestamp "$PTS_EPOCH")
            SORT_KEY="$PTS_EPOCH"
            STATUS="predicted"
        fi
    fi

    SAMPLE_AGE_SEC=$((NOW_EPOCH - LAST_SAMPLE_EPOCH))
    if (( SAMPLE_AGE_SEC < 0 )); then
        SAMPLE_AGE_LABEL="sample timestamp is in the future"
    else
        SAMPLE_AGE_LABEL="${SAMPLE_AGE_SEC}s"
    fi

    DETAIL_ROWS+=$(printf '%s\034%s\034%s/%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s' \
        "$SORT_KEY" "$CHANNEL" "$STREAM_INDEX" "$STREAM_TYPE" \
        "$NEXT_WRAP_FMT" "$WRAP_TICKS" "$PTS_LABEL" "$PTS_TICKS" \
        "$LAST_TS" "$FIRST_TS" "$SAMPLE_AGE_LABEL" "$FIRST_ODTS" "$LAST_ODTS" \
        "$FIRST_REF" "$LAST_REF" "$LAST_EPOCH" "$LAST_DTS" "$FIRST_INPUT" "$LAST_INPUT" \
        "$SAMPLE_COUNT" "$STATUS")
    DETAIL_ROWS+=$'\n'
done <<< "$PARSED_DATA"

if [[ -z "$DETAIL_ROWS" ]]; then
    echo "ERROR: No usable stream samples remained after validation." >&2
    exit 1
fi

SORTED_ROWS=$(printf '%s' "$DETAIL_ROWS" | sort -t $'\034' -k1,1n)

echo "Tvheadend estimates (lookback: $LOOKBACK)"
echo "Times are local projections from each stream's latest sample, sorted by PTS_UNSET."
echo

echo "FORECASTS"
printf '%-28s | %-23s | %-29s | %10s | %10s | %12s | %-20s\n' \
    "CHANNEL / STREAM" "NEXT DTS WRAP" "NEXT PTS_UNSET" \
    "WRAP TICKS" "PTS TICKS" "AGE / COUNT" "STATUS"
printf '%s\n' "$SORTED_ROWS" |
while IFS=$'\034' read -r SORT_KEY CHANNEL STREAM WRAP_TIME WRAP_TICKS \
    PTS_TIME PTS_TICKS SAMPLE_TIME FIRST_SAMPLE_TIME SAMPLE_AGE FIRST_ODTS ODTS \
    FIRST_REF REF EPOCH_FIELD PACKET_DTS FIRST_INPUT EFFECTIVE_DTS SAMPLE_COUNT STATUS; do
    [[ -n "$CHANNEL" ]] || continue
    printf '%-28s | %-23s | %-29s | %10s | %10s | %12s | %-20s\n' \
        "$CHANNEL / $STREAM" "$WRAP_TIME" "$PTS_TIME" "$WRAP_TICKS" "$PTS_TICKS" \
        "$SAMPLE_AGE / $SAMPLE_COUNT" "$STATUS"
done

echo
echo "TRACE VALUES"
printf '%-28s | %-24s | %-24s | %10s | %12s | %-25s\n' \
    "CHANNEL / STREAM" "ODTS (FIRST -> LAST)" "REF (FIRST -> LAST)" \
    "EPOCH" "PACKET_DTS" "EFFECTIVE INPUT (FIRST -> LAST)"
printf '%s\n' "$SORTED_ROWS" |
while IFS=$'\034' read -r SORT_KEY CHANNEL STREAM WRAP_TIME WRAP_TICKS \
    PTS_TIME PTS_TICKS SAMPLE_TIME FIRST_SAMPLE_TIME SAMPLE_AGE FIRST_ODTS ODTS \
    FIRST_REF REF EPOCH_FIELD PACKET_DTS FIRST_INPUT EFFECTIVE_DTS SAMPLE_COUNT STATUS; do
    [[ -n "$CHANNEL" ]] || continue
    printf '%-28s | %-24s | %-24s | %10s | %12s | %-25s\n' \
        "$CHANNEL / $STREAM" "$FIRST_ODTS -> $ODTS" "$FIRST_REF -> $REF" \
        "$EPOCH_FIELD" "$PACKET_DTS" "$FIRST_INPUT -> $EFFECTIVE_DTS"
done

echo
echo "Note: With ref=0, the original pts_diff() condition does not predict PTS_UNSET at the wrap."
echo "Original condition boundaries: QUARTER=$PTS_QUARTER, HALF=$PTS_HALF, modulo=$PTS_MODULO."
echo "The projection assumes continuous media time and an unchanged reference; rerun after a retune or discontinuity."
