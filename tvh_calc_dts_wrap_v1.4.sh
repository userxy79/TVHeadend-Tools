#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Tvheadend 33-bit MPEG-TS DTS wrap / legacy regression-test calculator (v1.4)
# -----------------------------------------------------------------------------
#
# PURPOSE
#   Analyse Tvheadend's tsfix trace for one active channel subscription and
#   calculate, separately for each elementary stream:
#
#     1. The next 33-bit DTS wrap (based on the reconstructed timestamp that
#        the original pts_diff() implementation would have received).
#     2. The point at which the ORIGINAL pts_diff() implementation would have
#        returned PTS_UNSET for this stream.
#     3. A suggested test end time, including an additional stability period
#        after that point.
#
#   The script also calculates one overall target for the subscription. The
#   target is the latest target among all continuous primary streams present
#   from the start of that subscription. Dynamically added auxiliary streams
#   (such as DVBSUB or secondary audio tracks enabled mid-broadcast via PMT
#   updates) and sparse subtitle streams (DVBSUB/TEXTSUB that pause between
#   subtitled programmes) are still analysed and tracked, but do not invalidate
#   the subscription-wide minimum as long as their reference clock remains
#   stable and their first observed sample is valid.
#
# BACKGROUND: THE 33-BIT MPEG CLOCK
#   MPEG-TS PTS/DTS values use a 33-bit counter with a 90 kHz clock:
#
#       PTS_MODULO = 2^33 = 8,589,934,592 ticks
#       PTS_MASK   = 2^33 - 1 = 8,589,934,591
#       one tick   = 1 / 90,000 second
#       full cycle = about 26 h 30 min 43.7 s
#
#   The counter wraps from PTS_MASK back to zero. This is normal MPEG-TS
#   behaviour and is not itself an error.
#
# BACKGROUND: THE ORIGINAL pts_diff() CONDITION
#   The original Tvheadend pts_diff(a,b) masks both arguments to 33 bits and
#   then applies this logic:
#
#       if (b < PTS_MASK/4 && a > PTS_MASK/2)
#           return b + PTS_MODULO - a;
#       else if (b >= a)
#           return b - a;
#       else
#           return PTS_UNSET;
#
#   With integer division, the relevant boundaries are:
#
#       QUARTER = PTS_MASK / 4 = 2,147,483,647
#       HALF    = PTS_MASK / 2 = 4,294,967,295
#
#   The comparisons are strict. In particular, b == QUARTER is no longer
#   handled by the wrap special case, and a == HALF does not activate it.
#
#   The time to the old PTS_UNSET condition depends on the reference 'a':
#
#   A) ref == 0
#      The old comparison does not enter the wrap-related PTS_UNSET condition.
#      The script therefore recommends covering the next complete wrap and
#      then continuing for the configured stability period. This is wrap
#      coverage, not a predicted reproduction of issue #1876.
#
#   B) 0 < ref <= HALF
#      The old code has no special wrap handling for this reference range.
#      Immediately after the counter wraps, b becomes smaller than ref and the
#      old function returns PTS_UNSET. The predicted failure point is the next
#      wrap.
#
#   C) ref > HALF
#      The old code temporarily handles the wrap while the post-wrap b value
#      remains below QUARTER. Once b reaches QUARTER, the special case stops
#      matching and the old function returns PTS_UNSET. The predicted failure
#      point is therefore after the wrap, at the QUARTER boundary.
#
#   This piecewise calculation is derived from the actual conditional logic in
#   pts_diff(). It also matches the failure-time examples listed in PR #2248.
#
# WHY THE SCRIPT DOES NOT USE odts ALONE
#   A tsfix trace record contains, among other fields:
#
#       odts ... ref ... epoch ... (pkt stream ... dts ...)
#
#   odts is the original packet DTS before normalization. It is useful for
#   diagnostics, but it is not necessarily the exact value that the old
#   pts_diff() would have received after a Timeshift skip.
#
#   In the current tsfix implementation, SMT_SKIP can enable a transport-wide
#   DTS offset. The trace's delivered packet DTS and epoch allow the effective
#   old input to be reconstructed modulo 2^33:
#
#       effective_input = (ref + delivered_dts - epoch) mod 2^33
#
#   The calculation below uses that reconstructed value. This is intended to
#   include the offset reflected in the delivered DTS, rather than relying on
#   odts alone. It also retains odts in the report for comparison.
#
# HOW AN OBSERVED LEGACY FAILURE POINT IS IDENTIFIED
#   The script does not treat every backward timestamp jump as proof of a
#   wrap. It checks for the expected boundary transition between consecutive
#   samples of the same stream:
#
#     - ref <= HALF: previous effective DTS was above HALF and the new value
#       is below ref (the counter crossed the 33-bit wrap).
#     - ref > HALF: previous effective DTS was below QUARTER and the new value
#       has reached or passed QUARTER while still below ref.
#
#   It additionally checks that the old pts_diff() predicate would return
#   PTS_UNSET for the new sample. The first such boundary transition is logged
#   as the observed legacy failure point. This means the fixed build's trace
#   has traversed the input condition that would have broken the old code.
#
#   If the first sample already lies in the old failure region, the trace may
#   have started too late. The script will not invent a crossing time; it marks
#   that stream as unsuitable for a reliable minimum-duration estimate.
#
# INITIAL TRACE GAP, DYNAMICALLY ADDED STREAMS & SPARSE SUBTITLES
#   Broadcasters frequently enable or disable elementary streams such as
#   DVBSUB subtitles or secondary audio PIDs mid-broadcast via PMT updates,
#   or stop transmitting subtitle packets during unsubtitled programmes:
#
#     - Late auxiliary start: When a stream matching DYNAMIC_STREAM_TYPES first
#       appears more than MAX_INITIAL_TRACE_GAP_SEC after subscription start,
#       it is still fully evaluated for reference stability, wrap projection,
#       and legacy PTS_UNSET boundary crossings. Provided its reference clock
#       is stable, its first sample is outside the legacy failure region, and
#       its trace is fresh, it is classified as a "dynamic mid-stream addition"
#       rather than invalidating the subscription's overall minimum target.
#     - Sparse subtitle pause: When a stream matching SPARSE_STREAM_TYPES
#       (e.g. DVBSUB/TEXTSUB) had a valid start and stable reference clock,
#       but later stops emitting packets for longer than MAX_TRACE_AGE_SEC
#       while continuous primary streams remain active, it is treated as a
#       paused sparse auxiliary stream rather than invalidating the overall
#       subscription target.
#     - If a primary stream (e.g. H264/HEVC/MPEG2VIDEO) exceeds the initial
#       trace gap or goes stale, logging started late or stalled and the
#       overall target remains marked unreliable.
#
# TEST DURATION AND THE EXTRA STABILITY PERIOD
#   SOAK_AFTER_FAILURE_SEC controls how long the test should continue after the
#   observed or predicted legacy failure point. The default is one hour.
#
#   This is a practical test criterion, not a mathematical proof of 100%
#   correctness. A finite run cannot prove that all stream combinations,
#   discontinuities, service restarts or client behaviours are correct.
#
#   For ref == 0, where this particular old pts_diff() failure is not predicted,
#   the target is the next full DTS wrap plus the extra stability period.
#
# LOGGING REQUIREMENTS IN TVHEADEND
#   Enable the following logging settings in TVHeadend:
#
#     - Enable syslog:            Yes
#     - Debug to syslog:          Yes
#     - Debug subsystems:         all
#     - Debug trace (low-level):  Yes
#     - Trace subsystems:         tsfix
#
#   The script reads these message types:
#
#     - subscribing on channel
#     - unsubscribing from
#     - tsfix: deliver
#
# IMPORTANT LIMITATIONS AND ASSUMPTIONS
#   - Run only ONE channel subscription at a time. tsfix: deliver records do
#     not contain a channel name or subscription ID. If more than one channel
#     subscription is active, those trace records are ambiguous and skipped.
#   - The subscription start and first tsfix trace records must be present in
#     the journal lookback window. LOOKBACK accepts minutes, hours, or a
#     combination of both, up to 168 hours (7 days). The script checks for an
#     initial sample that is already in the old failure region, but cannot
#     prove that logging was enabled from the very first packet. Inspect the
#     reported start/sample times if the trace may have started late.
#   - A stable reference is required for the projection. If ref changes during
#     any stream (primary or auxiliary), the script marks the estimate invalid
#     for the subscription.
#   - A fresh subscription is required if the first observed sample is already
#     in the old failure region. This avoids treating an unknown earlier event
#     as a successful observed crossing.
#   - The wall-clock estimate assumes the effective 90 kHz media timestamp
#     continues to advance at normal rate. Pauses, source outages, large jumps,
#     stream restarts or later offset changes can move the predicted time.
#     Re-run the script during the test to refresh the projection.
#   - The trace must contain ref, epoch and the delivered packet dts field.
#     Records that do not contain these fields are ignored.
#   - The stream index/type in the trace is used to keep H264, AC3, Teletext,
#     subtitles and other elementary streams separate.
#   - A stale trace sample on any continuous stream is not accepted as a
#     current prediction.
#   - Trace freshness (MAX_TRACE_AGE_SEC) is measured against the timestamp at
#     script invocation (before journalctl scans multi-GB logs) so long
#     journal scan times never cause false STALE classifications.
#   - The script does not certify Timeshift playback quality by itself. The
#     client must still be exercised (play, pause, seek in both directions).
#
# DEFAULTS
#   TVH_UNIT                    tvheadend.service
#   LOOKBACK                    1 hour ago (maximum 168 hours / 7 days)
#   SOAK_AFTER_FAILURE_SEC      3600 (one additional hour)
#   MAX_TRACE_AGE_SEC           180 (latest trace must be no older than 3 min)
#   MAX_INITIAL_TRACE_GAP_SEC   180 (first trace of primary streams should
#                               follow subscription start within 3 min)
#   DYNAMIC_STREAM_TYPES        DVBSUB|TEXTSUB|TELETEXT|AC3|EAC3|AAC|MPEG2AUDIO|VORBIS|OPUS
#   SPARSE_STREAM_TYPES         DVBSUB|TEXTSUB
#
# OVERRIDES EXAMPLES 
#   TVH_UNIT=tvheadend.service ./tvh_calc_dts_wrap_v1.4.sh
#   SOAK_AFTER_FAILURE_SEC=7200 ./tvh_calc_dts_wrap_v1.4.sh
#   LOOKBACK='3 hours 35 minutes ago' ./tvh_calc_dts_wrap_v1.4.sh
#   LOOKBACK='168 hours ago' ./tvh_calc_dts_wrap_v1.4.sh
#
# USAGE
#   chmod +x tvh_calc_dts_wrap_v1.4.sh
#   ./tvh_calc_dts_wrap_v1.4.sh
#
# REQUIREMENTS
#   Bash 4+, journalctl with --grep support, GNU date, awk and sort.
#   Non-root users need sudo permission to read the system journal.
# -----------------------------------------------------------------------------

set -Eeuo pipefail
export LC_ALL=C

# ----------------------------- Configuration ---------------------------------

TVH_UNIT="${TVH_UNIT:-tvheadend.service}"
LOOKBACK="${LOOKBACK:-1 hour ago}"
SOAK_AFTER_FAILURE_SEC="${SOAK_AFTER_FAILURE_SEC:-3600}"
MAX_TRACE_AGE_SEC="${MAX_TRACE_AGE_SEC:-180}"
MAX_INITIAL_TRACE_GAP_SEC="${MAX_INITIAL_TRACE_GAP_SEC:-180}"
DYNAMIC_STREAM_TYPES="${DYNAMIC_STREAM_TYPES:-DVBSUB|TEXTSUB|TELETEXT|AC3|EAC3|AAC|MPEG2AUDIO|VORBIS|OPUS}"
SPARSE_STREAM_TYPES="${SPARSE_STREAM_TYPES:-DVBSUB|TEXTSUB}"

# MPEG-TS clock constants. PTS_MASK is the largest legal 33-bit value;
# PTS_MODULO is the number of values in a complete counter cycle.
PTS_MASK=8589934591                 # 2^33 - 1
PTS_MODULO=8589934592                # 2^33
CLOCK_HZ=90000                       # 90 kHz MPEG timestamp clock
PTS_QUARTER=$((PTS_MASK / 4))        # 2,147,483,647 (C integer division)
PTS_HALF=$((PTS_MASK / 2))           # 4,294,967,295 (C integer division)

JOURNAL_FILTER='subscribing on channel|unsubscribing from|tsfix: deliver'

# ------------------------------- Validation ----------------------------------

for VARIABLE in SOAK_AFTER_FAILURE_SEC MAX_TRACE_AGE_SEC MAX_INITIAL_TRACE_GAP_SEC; do
    VALUE="${!VARIABLE}"
    if ! [[ "$VALUE" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $VARIABLE must be a non-negative integer; got '$VALUE'." >&2
        exit 1
    fi
done

if [[ "$LOOKBACK" =~ ^([0-9]{1,3})[[:space:]]+hours?[[:space:]]+([0-9]{1,5})[[:space:]]+minutes?[[:space:]]+ago$ ]]; then
    LOOKBACK_HOURS=$((10#${BASH_REMATCH[1]}))
    LOOKBACK_EXTRA_MINUTES=$((10#${BASH_REMATCH[2]}))
    LOOKBACK_TOTAL_MINUTES=$((LOOKBACK_HOURS * 60 + LOOKBACK_EXTRA_MINUTES))
elif [[ "$LOOKBACK" =~ ^([0-9]{1,3})[[:space:]]+hours?[[:space:]]+ago$ ]]; then
    LOOKBACK_HOURS=$((10#${BASH_REMATCH[1]}))
    LOOKBACK_TOTAL_MINUTES=$((LOOKBACK_HOURS * 60))
elif [[ "$LOOKBACK" =~ ^([0-9]{1,5})[[:space:]]+minutes?[[:space:]]+ago$ ]]; then
    LOOKBACK_TOTAL_MINUTES=$((10#${BASH_REMATCH[1]}))
else
    echo "ERROR: LOOKBACK must be minutes, hours, or hours plus minutes, followed by 'ago'." >&2
    echo "Examples: '30 minutes ago', '9 hours ago', '3 hours 35 minutes ago'." >&2
    exit 1
fi
if (( LOOKBACK_TOTAL_MINUTES < 1 || LOOKBACK_TOTAL_MINUTES > 10080 )); then
    echo "ERROR: LOOKBACK must be between 1 minute and 168 hours (7 days)." >&2
    exit 1
fi
LOOKBACK_JOURNAL_SINCE="${LOOKBACK_TOTAL_MINUTES} minutes ago"

if ! command -v journalctl >/dev/null 2>&1; then
    echo "ERROR: journalctl was not found." >&2
    exit 1
fi

if ! command -v awk >/dev/null 2>&1 || ! command -v sort >/dev/null 2>&1; then
    echo "ERROR: awk and sort are required." >&2
    exit 1
fi

if ! command -v date >/dev/null 2>&1 || ! date --version 2>/dev/null | grep -q 'GNU coreutils'; then
    echo "ERROR: GNU date (coreutils) is required." >&2
    exit 1
fi

if (( EUID == 0 )); then
    JOURNAL_CMD=(journalctl)
else
    if ! command -v sudo >/dev/null 2>&1; then
        echo "ERROR: sudo is required when the script is not run as root." >&2
        exit 1
    fi
    JOURNAL_CMD=(sudo journalctl)
fi

# --------------------- Read & parse subscription/trace data ------------------
#
# Capture NOW_EPOCH *before* invoking journalctl so multi-GB log scan duration
# never inflates SAMPLE_AGE_SEC into a false STALE state. Stream directly into
# awk rather than buffering gigabytes of matching lines in a shell variable.
#
# A tsfix: deliver line has no channel or subscription ID. We therefore use
# subscription log messages to maintain a list of active subscriptions.
# Trace lines are accepted only when exactly one subscription is active.
#
# A unique internal session number is assigned whenever a channel subscription
# starts. The TVH subscription ID is used to match its unsubscribe message.
# This also handles TVH reusing a subscription ID later in the journal.
#
# For every stream we retain the first and latest samples, reference changes,
# and the first observed transition into the old pts_diff() failure condition.

echo "Analyzing Tvheadend tsfix trace..."
echo "  Unit:                       $TVH_UNIT"
echo "  Lookback:                   $LOOKBACK"
echo "  Additional stability time: ${SOAK_AFTER_FAILURE_SEC}s"
echo

NOW_EPOCH=$(date +%s)

PARSED_WITH_STATUS=$(
    set +e
    "${JOURNAL_CMD[@]}" \
    --unit "$TVH_UNIT" \
    --since "$LOOKBACK_JOURNAL_SINCE" \
    --until "@$NOW_EPOCH" \
    --no-pager \
    --output=short-iso-precise \
    --grep="$JOURNAL_FILTER" | awk '
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

function active_subscription_count( sid, count) {
    count = 0
    for (sid in active_session)
        count++
    return count
}

function only_active_session( sid, result) {
    result = ""
    for (sid in active_session)
        result = active_session[sid]
    return result
}

# Exact old pts_diff() PTS_UNSET predicate after masking a and b to 33 bits.
function legacy_pts_diff_is_unset(a, b) {
    return (b < a && !(b < 2147483647 && a > 4294967295))
}

{
    lines_seen++
    timestamp = $1

    # Begin a subscription session.
    if ($0 ~ /subscribing on channel "/) {
        sid = get_subscription_id($0)
        channel_name = get_channel_name($0)

        if (sid != "" && channel_name != "") {
            session_number++
            active_session[sid] = session_number
            session_channel[session_number] = channel_name
            session_sid[session_number] = sid
            session_start[session_number] = timestamp
            session_active[session_number] = 1
            next
        }
    }

    # End a subscription session. The session remains in the report but is
    # marked inactive, so it cannot be mistaken for a currently running test.
    if ($0 ~ /unsubscribing from/) {
        sid = get_subscription_id($0)
        if (sid != "" && (sid in active_session)) {
            ended_session = active_session[sid]
            session_active[ended_session] = 0
            delete active_session[sid]
            next
        }
    }

    if ($0 !~ /tsfix: deliver/)
        next

    # Extract original DTS (odts), reference, epoch and delivered packet DTS.
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

    # Leading space prevents a match inside the field name "odts".
    if (!match($0, / dts -?[0-9]+/))
        next
    norm_dts_text = substr($0, RSTART, RLENGTH)
    sub(/^ dts /, "", norm_dts_text)

    # Identify elementary stream, e.g. "pkt stream 1 H264".
    if (!match($0, /pkt stream [0-9]+ [[:alnum:]_+-]+/))
        next
    stream_text = substr($0, RSTART, RLENGTH)
    sub(/^pkt stream /, "", stream_text)
    split(stream_text, stream_fields, /[[:space:]]+/)
    stream_index = stream_fields[1]
    stream_type = stream_fields[2]

    # Negative values indicate unset/sentinel data and cannot be used here.
    if ((odts_text + 0) < 0 || (ref_text + 0) < 0 ||
        (norm_dts_text + 0) < 0)
        next

    # Associate this trace only when exactly one subscription is active.
    active_count = active_subscription_count()
    if (active_count == 0) {
        unassigned_trace++
        next
    }
    if (active_count > 1) {
        ambiguous_trace++
        next
    }

    session = only_active_session()
    key = session SUBSEP stream_index SUBSEP stream_type

    # All values are below 2^33 (or small epoch offsets), well within the exact
    # integer range of the usual IEEE-754 double used by awk.
    ref_value = (ref_text + 0) % 8589934592
    odts_value = (odts_text + 0) % 8589934592

    # Reconstruct the old pts_diff() input modulo 2^33:
    #   effective = (ref + delivered_normalized_dts - epoch) mod 2^33
    effective_value = (ref_value + (norm_dts_text + 0) - (epoch_text + 0)) % 8589934592
    if (effective_value < 0)
        effective_value += 8589934592

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

        # Only accept a boundary crossing, not an arbitrary backward jump.
        # For ref <= HALF, the wrap itself enters the old failure region.
        # For ref > HALF, the old special case stops working at QUARTER.
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
            } else {
                boundary_crossed = 0
            }

            if (boundary_crossed)
                legacy_failure_timestamp[key] = timestamp
        }
    }

    last_timestamp[key] = timestamp
    last_effective[key] = effective_value
    last_ref[key] = ref_value
    last_odts[key] = odts_value
    sample_count[key]++
}

END {
    if (lines_seen == 0)
        exit 3

    # Emit metadata before DATA records so the shell knows which subscriptions
    # are still active before calculating their test targets.
    printf "META\t%d\t%d\n", ambiguous_trace, unassigned_trace
    for (session in session_channel)
        printf "SESSION\t%s\t%d\n", session, session_active[session]

    for (key in sample_count) {
        session = key_session[key]
        failure_ts = legacy_failure_timestamp[key]
        if (failure_ts == "")
            failure_ts = "NONE"

        # 18 tab-separated fields after DATA. NONE replaces an empty timestamp
        # because Bash treats adjacent tab delimiters as one IFS separator.
        printf "DATA\t%s\t%s\t%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.0f\t%s\t%s\t%.0f\t%.0f\t%.0f\t%s\t%d\t%d\t%d\n", \
            session, session_channel[session], session_sid[session], \
            session_start[session], key_stream_index[key], key_stream_type[key], \
            first_effective[key], first_ref[key], first_odts[key], \
            first_timestamp[key], last_timestamp[key], last_effective[key], \
            last_ref[key], last_odts[key], failure_ts, first_invalid[key], \
            sample_count[key], ref_changed[key]
    }
}
'
    PIPE_STATUS=("${PIPESTATUS[@]}")
    printf '\034%d\t%d' "${PIPE_STATUS[0]:-1}" "${PIPE_STATUS[1]:-1}"
)

PIPE_STATUS_TEXT="${PARSED_WITH_STATUS##*$'\034'}"
PARSED_DATA="${PARSED_WITH_STATUS%$'\034'*}"
IFS=$'\t' read -r JOURNAL_RC AWK_RC <<< "$PIPE_STATUS_TEXT"

if (( JOURNAL_RC != 0 )); then
    echo "ERROR: Could not read/filter the Tvheadend journal." >&2
    echo "Check the unit name, journal permissions and journalctl --grep support." >&2
    exit 1
fi

if (( AWK_RC == 3 )); then
    echo "ERROR: No matching subscription or tsfix trace entries were found." >&2
    echo "Check the TVHeadend logging requirements at the top of this script." >&2
    exit 1
elif (( AWK_RC != 0 )); then
    echo "ERROR: Failed to parse Tvheadend journal records (awk exit $AWK_RC)." >&2
    exit 1
fi

if [[ -z "$PARSED_DATA" ]]; then
    echo "ERROR: No usable tsfix: deliver records could be associated with a channel." >&2
    echo "Ensure the subscription start is inside LOOKBACK and only one channel" >&2
    echo "subscription is active while the trace is being generated." >&2
    exit 1
fi

# ------------------------------ Helper functions -----------------------------

to_epoch() {
    date -d "$1" +%s
}

format_duration() {
    local total="$1"
    local days hours minutes seconds

    days=$((total / 86400))
    hours=$(((total % 86400) / 3600))
    minutes=$(((total % 3600) / 60))
    seconds=$((total % 60))

    if (( days > 0 )); then
        printf '%dd %02d:%02d:%02d' "$days" "$hours" "$minutes" "$seconds"
    else
        printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
    fi
}

format_timestamp() {
    date -d "@$1" '+%d.%m.%Y %H:%M:%S'
}

# Round positive 90 kHz ticks UP to the next whole second. Rounding down could
# make the suggested test end slightly earlier than the calculated boundary.
ticks_to_seconds_ceil() {
    local ticks="$1"
    printf '%s' "$(((ticks + CLOCK_HZ - 1) / CLOCK_HZ))"
}

# Check whether a stream type is allowed to appear dynamically mid-broadcast
# (e.g. DVBSUB subtitles or secondary audio PIDs added via PMT update).
is_dynamic_stream_type() {
    local stype="$1"
    [[ "$stype" =~ ^(${DYNAMIC_STREAM_TYPES})$ ]]
}

# Check whether a stream type is discrete/episodic (e.g. DVB/teletext bitmap
# subtitles that pause when an unsubtitled programme airs).
is_sparse_stream_type() {
    local stype="$1"
    [[ "$stype" =~ ^(${SPARSE_STREAM_TYPES})$ ]]
}

# Return ticks until the original pts_diff() predicate is expected to return
# PTS_UNSET, based on the most recent reconstructed effective DTS.
#
# Return values:
#   positive integer: predicted ticks until the old failure condition
#   0:                current value is already in the old failure region
#  -1:               ref == 0; this particular old failure is not predicted
legacy_failure_ticks_remaining() {
    local dts="$1"
    local ref="$2"

    if (( ref == 0 )); then
        printf '%s' '-1'
        return
    fi

    if (( ref > PTS_HALF )); then
        # Wrap is handled only while post-wrap DTS < QUARTER. Failure starts
        # at DTS == QUARTER because the original C comparison is strict '<'.
        if (( dts >= ref )); then
            printf '%s' "$((PTS_MODULO - dts + PTS_QUARTER))"
        elif (( dts < PTS_QUARTER )); then
            printf '%s' "$((PTS_QUARTER - dts))"
        else
            printf '%s' '0'
        fi
    else
        # No special wrap handling for this reference. Failure begins just
        # after the counter wraps and the new DTS becomes smaller than ref.
        if (( dts >= ref )); then
            printf '%s' "$((PTS_MODULO - dts))"
        else
            printf '%s' '0'
        fi
    fi
}

# ------------------------------ Build report ---------------------------------

DETAIL_ROWS=""
META_AMBIGUOUS=0
META_UNASSIGNED=0

# Per-session aggregate. The whole channel test must continue until the last
# continuous primary elementary stream has passed its target.
declare -A SESSION_CHANNEL=()
declare -A SESSION_SUB_START=()
declare -A SESSION_TARGET=()
declare -A SESSION_INVALID=()
declare -A SESSION_STREAMS=()
declare -A SESSION_PRIMARY_STREAMS=()
declare -A SESSION_AUXILIARY_STREAMS=()
declare -A SESSION_ACTIVE=()

while IFS=$'\t' read -r KIND SESSION CHANNEL SUB_ID SUB_START \
    STREAM_INDEX STREAM_TYPE FIRST_INPUT FIRST_REF FIRST_ODTS FIRST_TS \
    LAST_TS LAST_INPUT LAST_REF LAST_ODTS LEGACY_FAILURE_TS \
    FIRST_INVALID PACKET_COUNT REF_CHANGED; do

    case "$KIND" in
        META)
            META_AMBIGUOUS="${SESSION:-0}"
            META_UNASSIGNED="${CHANNEL:-0}"
            continue
            ;;
        SESSION)
            SESSION_ACTIVE["$SESSION"]="${CHANNEL:-0}"
            continue
            ;;
        DATA)
            ;;
        *)
            continue
            ;;
    esac

    # Validate numeric fields before using them in Bash arithmetic.
    VALID_ROW=1
    for VALUE_NAME in FIRST_INPUT FIRST_REF FIRST_ODTS LAST_INPUT LAST_REF LAST_ODTS; do
        VALUE="${!VALUE_NAME}"
        if ! [[ "$VALUE" =~ ^[0-9]+$ ]]; then
            echo "WARNING: Invalid $VALUE_NAME value for $CHANNEL / $STREAM_TYPE: '$VALUE'." >&2
            VALID_ROW=0
            break
        fi
    done
    if (( VALID_ROW == 0 )); then
        SESSION_INVALID["$SESSION"]=1
        continue
    fi

    FIRST_INPUT=$((10#$FIRST_INPUT % PTS_MODULO))
    FIRST_REF=$((10#$FIRST_REF % PTS_MODULO))
    FIRST_ODTS=$((10#$FIRST_ODTS % PTS_MODULO))
    LAST_INPUT=$((10#$LAST_INPUT % PTS_MODULO))
    LAST_REF=$((10#$LAST_REF % PTS_MODULO))
    LAST_ODTS=$((10#$LAST_ODTS % PTS_MODULO))

    if ! SUB_START_EPOCH=$(to_epoch "$SUB_START") || \
       ! LAST_EPOCH=$(to_epoch "$LAST_TS"); then
        echo "WARNING: Could not parse timestamps for $CHANNEL / $STREAM_TYPE." >&2
        SESSION_INVALID["$SESSION"]=1
        continue
    fi

    STREAM_IS_INVALID=0
    STREAM_IS_AUXILIARY=0
    STREAM_AUX_REASON=""

    # Reject estimates if the stream's reference changed during the trace.
    if [[ "$REF_CHANGED" == "1" || "$FIRST_REF" -ne "$LAST_REF" ]]; then
        REF_STATUS="CHANGED"
        STREAM_IS_INVALID=1
    else
        REF_STATUS="stable"
    fi

    # Check initial trace gap. Primary streams must appear shortly after
    # subscription start; auxiliary streams (e.g. DVBSUB) may be added later
    # via PMT update without invalidating the subscription's overall target.
    if ! FIRST_SAMPLE_EPOCH=$(to_epoch "$FIRST_TS"); then
        FIRST_SAMPLE_EPOCH="$SUB_START_EPOCH"
        FIRST_GAP_SEC=999999
        STREAM_IS_INVALID=1
    else
        FIRST_GAP_SEC=$((FIRST_SAMPLE_EPOCH - SUB_START_EPOCH))
        if (( FIRST_GAP_SEC < 0 )); then
            STREAM_IS_INVALID=1
        elif (( FIRST_GAP_SEC > MAX_INITIAL_TRACE_GAP_SEC )); then
            if is_dynamic_stream_type "$STREAM_TYPE"; then
                STREAM_IS_AUXILIARY=1
                STREAM_AUX_REASON="dynamic mid-stream addition"
            else
                STREAM_IS_INVALID=1
            fi
        fi
    fi

    # NEXT DTS WRAP is projected from the latest reconstructed input DTS.
    WRAP_TICKS=$((PTS_MODULO - LAST_INPUT))
    WRAP_SEC=$(ticks_to_seconds_ceil "$WRAP_TICKS")
    NEXT_WRAP_EPOCH=$((LAST_EPOCH + WRAP_SEC))

    if [[ "$REF_STATUS" == "CHANGED" ]]; then
        LEGACY_LABEL="reference changed"
        TARGET_EPOCH=0
        TOTAL_TEST_SEC=0
        STATUS="Reference changed; estimate invalid"
        STREAM_IS_INVALID=1
    elif [[ "$FIRST_INVALID" == "1" ]]; then
        LEGACY_LABEL="invalid at first sample"
        TARGET_EPOCH=0
        TOTAL_TEST_SEC=0
        STATUS="No reliable crossing time; start a fresh subscription"
        STREAM_IS_INVALID=1
    elif [[ "$LEGACY_FAILURE_TS" != "NONE" && -n "$LEGACY_FAILURE_TS" ]]; then
        # The actual old pts_diff() boundary crossing was seen in this fixed
        # build's trace. Continue the configured soak period beyond that point.
        if ! LEGACY_FAIL_EPOCH=$(to_epoch "$LEGACY_FAILURE_TS"); then
            LEGACY_LABEL="timestamp parse error"
            TARGET_EPOCH=0
            TOTAL_TEST_SEC=0
            STATUS="Could not parse the observed boundary timestamp"
            STREAM_IS_INVALID=1
        else
            TARGET_EPOCH=$((LEGACY_FAIL_EPOCH + SOAK_AFTER_FAILURE_SEC))
            LEGACY_LABEL="observed $(format_timestamp "$LEGACY_FAIL_EPOCH")"
            TOTAL_TEST_SEC=$((TARGET_EPOCH - SUB_START_EPOCH))
            STATUS="boundary observed + stability period"
        fi
    else
        # The old boundary has not yet been observed. Predict the remaining
        # media ticks from the latest sample and project them into wall time.
        LEGACY_TICKS=$(legacy_failure_ticks_remaining "$LAST_INPUT" "$LAST_REF")

        if (( LEGACY_TICKS == -1 )); then
            LEGACY_LABEL="not expected (ref=0)"
            TARGET_EPOCH=$((NEXT_WRAP_EPOCH + SOAK_AFTER_FAILURE_SEC))
            TOTAL_TEST_SEC=$((TARGET_EPOCH - SUB_START_EPOCH))
            STATUS="next wrap coverage + stability period"
        elif (( LEGACY_TICKS == 0 )); then
            LEGACY_LABEL="already in failure region"
            TARGET_EPOCH=0
            TOTAL_TEST_SEC=0
            STATUS="Crossing not present in log; start a fresh subscription"
            STREAM_IS_INVALID=1
        else
            LEGACY_SEC=$(ticks_to_seconds_ceil "$LEGACY_TICKS")
            LEGACY_FAIL_EPOCH=$((LAST_EPOCH + LEGACY_SEC))
            TARGET_EPOCH=$((LEGACY_FAIL_EPOCH + SOAK_AFTER_FAILURE_SEC))
            LEGACY_LABEL="predicted $(format_timestamp "$LEGACY_FAIL_EPOCH")"
            TOTAL_TEST_SEC=$((TARGET_EPOCH - SUB_START_EPOCH))
            STATUS="predicted old boundary + stability period"
        fi
    fi

    # Append initial-gap classification to STATUS.
    if (( FIRST_GAP_SEC < 0 )); then
        STATUS+="; first trace precedes subscription start"
    elif (( FIRST_GAP_SEC > MAX_INITIAL_TRACE_GAP_SEC )); then
        if (( STREAM_IS_AUXILIARY == 1 )); then
            STATUS+="; ${STREAM_AUX_REASON} (excluded from overall minimum)"
        else
            STATUS+="; first trace gap exceeds limit"
        fi
    fi

    # Validate that the latest trace is current against NOW_EPOCH (captured
    # before journalctl started). Continuous streams must stay fresh; sparse
    # subtitle streams (DVBSUB/TEXTSUB) may legitimately pause between
    # subtitled broadcasts without invalidating the subscription.
    SAMPLE_AGE_SEC=$((NOW_EPOCH - LAST_EPOCH))
    if (( SAMPLE_AGE_SEC < 0 )); then
        SAMPLE_AGE_SEC=0
        STATUS+="; journal timestamp is in the future"
        STREAM_IS_INVALID=1
    elif (( SAMPLE_AGE_SEC > MAX_TRACE_AGE_SEC )); then
        if (( STREAM_IS_INVALID == 0 )) && is_sparse_stream_type "$STREAM_TYPE"; then
            if (( STREAM_IS_AUXILIARY == 0 )); then
                STATUS+="; sparse subtitle stream paused (excluded from overall minimum)"
            else
                STATUS+="; sparse subtitle stream paused"
            fi
            STREAM_IS_AUXILIARY=1
        else
            STATUS+="; latest trace is stale"
            STREAM_IS_INVALID=1
        fi
    fi

    # A subscription that already ended is not a currently running test.
    if [[ "${SESSION_ACTIVE[$SESSION]:-0}" != "1" ]]; then
        STATUS+="; subscription is not active"
        STREAM_IS_INVALID=1
    fi

    if (( TARGET_EPOCH > 0 )); then
        TEST_END_LABEL=$(format_timestamp "$TARGET_EPOCH")
        REMAINING_SEC=$((TARGET_EPOCH - NOW_EPOCH))
        if (( REMAINING_SEC >= 0 )); then
            REMAINING_LABEL=$(format_duration "$REMAINING_SEC")
        else
            REMAINING_LABEL="passed $(format_duration "$((-REMAINING_SEC))") ago"
        fi
        TOTAL_LABEL=$(format_duration "$TOTAL_TEST_SEC")
    else
        TEST_END_LABEL="not calculable"
        REMAINING_LABEL="not calculable"
        TOTAL_LABEL="not calculable"
    fi

    if (( SAMPLE_AGE_SEC <= MAX_TRACE_AGE_SEC )); then
        SAMPLE_AGE_LABEL="${SAMPLE_AGE_SEC}s"
    elif (( STREAM_IS_AUXILIARY == 1 && STREAM_IS_INVALID == 0 )); then
        SAMPLE_AGE_LABEL="PAUSED ${SAMPLE_AGE_SEC}s"
    else
        SAMPLE_AGE_LABEL="STALE ${SAMPLE_AGE_SEC}s"
    fi

    NEXT_WRAP_LABEL=$(format_timestamp "$NEXT_WRAP_EPOCH")
    LAST_SAMPLE_LABEL=$(format_timestamp "$LAST_EPOCH")

    if (( TARGET_EPOCH > 0 )); then
        SORT_KEY="$TARGET_EPOCH"
    else
        SORT_KEY=9999999999
    fi

    # Save table data for chronological sorting after all streams are parsed.
    DETAIL_ROWS+=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$SORT_KEY" "$CHANNEL" "${STREAM_INDEX}/${STREAM_TYPE}" \
        "$FIRST_INPUT" "$LAST_INPUT" "$LAST_ODTS" "$LAST_REF" \
        "$(format_timestamp "$FIRST_SAMPLE_EPOCH")" "$FIRST_GAP_SEC" \
        "$LAST_SAMPLE_LABEL" "$NEXT_WRAP_LABEL" "$LEGACY_LABEL" \
        "$TEST_END_LABEL" "$TOTAL_LABEL" "$REMAINING_LABEL" "$SAMPLE_AGE_LABEL" "$STATUS")
    DETAIL_ROWS+=$'\n'

    SESSION_CHANNEL["$SESSION"]="$CHANNEL"
    SESSION_SUB_START["$SESSION"]="$SUB_START_EPOCH"
    SESSION_STREAMS["$SESSION"]=$(( ${SESSION_STREAMS["$SESSION"]:-0} + 1 ))

    if (( STREAM_IS_INVALID == 1 )); then
        SESSION_INVALID["$SESSION"]=1
    elif (( STREAM_IS_AUXILIARY == 1 )); then
        SESSION_AUXILIARY_STREAMS["$SESSION"]=$(( ${SESSION_AUXILIARY_STREAMS["$SESSION"]:-0} + 1 ))
    else
        SESSION_PRIMARY_STREAMS["$SESSION"]=$(( ${SESSION_PRIMARY_STREAMS["$SESSION"]:-0} + 1 ))
        if (( TARGET_EPOCH > 0 )); then
            if [[ -z "${SESSION_TARGET[$SESSION]:-}" ]] || \
               (( TARGET_EPOCH > SESSION_TARGET[$SESSION] )); then
                SESSION_TARGET["$SESSION"]="$TARGET_EPOCH"
            fi
        else
            SESSION_INVALID["$SESSION"]=1
        fi
    fi

done <<< "$PARSED_DATA"

if [[ -z "$DETAIL_ROWS" ]]; then
    echo "ERROR: No usable stream samples remained after validation." >&2
    echo "Check that trace records contain odts, ref, epoch and packet dts." >&2
    exit 1
fi

# --------------------------------- Output -------------------------------------

echo "========================================================================================================================"
printf '%-24s | %-12s | %-11s | %-11s | %-11s | %-11s | %-19s | %-27s\n' \
    "CHANNEL" "STREAM" "INPUT START" "INPUT NOW" "ODTS NOW" "REF" "NEXT DTS WRAP" "LEGACY PTS_UNSET"
echo "------------------------------------------------------------------------------------------------------------------------"

printf '%s' "$DETAIL_ROWS" | sort -t $'\t' -k1,1n | \
while IFS=$'\t' read -r SORT_KEY CHANNEL STREAM FIRST_INPUT LAST_INPUT LAST_ODTS REF \
    FIRST_SAMPLE FIRST_GAP LAST_SAMPLE NEXT_WRAP LEGACY_FAILURE TEST_END TOTAL_MIN REMAINING SAMPLE_AGE STATUS; do
    [[ -n "$CHANNEL" ]] || continue
    printf '%-24.24s | %-12s | %-11s | %-11s | %-11s | %-11s | %-19s | %-27s\n' \
        "$CHANNEL" "$STREAM" "$FIRST_INPUT" "$LAST_INPUT" "$LAST_ODTS" "$REF" \
        "$NEXT_WRAP" "$LEGACY_FAILURE"
    printf '  First trace: %-19s (subscription gap: %ss)  Latest trace: %-19s  Suggested end: %-19s\n' \
        "$FIRST_SAMPLE" "$FIRST_GAP" "$LAST_SAMPLE" "$TEST_END"
    printf '  Minimum runtime: %-12s  Remaining: %-18s  Trace age: %s (max %ss)\n' \
        "$TOTAL_MIN" "$REMAINING" "$SAMPLE_AGE" "$MAX_TRACE_AGE_SEC"
    printf '  Assessment: %s\n' "$STATUS"
done

echo "========================================================================================================================"
echo
echo "OVERALL TEST TARGET PER SUBSCRIPTION"
echo "---------------------------------------------------------------------------------------------------------------"

for SESSION in "${!SESSION_CHANNEL[@]}"; do
    CHANNEL="${SESSION_CHANNEL[$SESSION]}"
    START_EPOCH="${SESSION_SUB_START[$SESSION]}"
    STREAMS="${SESSION_STREAMS[$SESSION]}"
    PRIMARY_COUNT="${SESSION_PRIMARY_STREAMS[$SESSION]:-0}"
    AUX_COUNT="${SESSION_AUXILIARY_STREAMS[$SESSION]:-0}"

    if [[ -n "${SESSION_INVALID[$SESSION]:-}" || -z "${SESSION_TARGET[$SESSION]:-}" || "$PRIMARY_COUNT" -eq 0 ]]; then
        printf '%s (%s streams): NO RELIABLE OVERALL MINIMUM\n' "$CHANNEL" "$STREAMS"
        echo "  Reason: at least one primary stream has a changed reference, an unobserved"
        echo "  starting boundary, a stale trace, or an inactive/ambiguous subscription."
        continue
    fi

    TARGET="${SESSION_TARGET[$SESSION]}"
    TOTAL_SEC=$((TARGET - START_EPOCH))
    REMAINING_SEC=$((TARGET - NOW_EPOCH))

    if (( AUX_COUNT > 0 )); then
        printf '%s (%s streams: %s primary, %s dynamic/sparse):\n' \
            "$CHANNEL" "$STREAMS" "$PRIMARY_COUNT" "$AUX_COUNT"
    else
        printf '%s (%s primary streams):\n' "$CHANNEL" "$PRIMARY_COUNT"
    fi

    printf '  Subscription start:       %s\n' "$(format_timestamp "$START_EPOCH")"
    printf '  Recommended test end:     %s\n' "$(format_timestamp "$TARGET")"
    printf '  Minimum total runtime:    %s\n' "$(format_duration "$TOTAL_SEC")"

    if (( REMAINING_SEC >= 0 )); then
        printf '  Remaining from now:       %s\n' "$(format_duration "$REMAINING_SEC")"
    else
        printf '  Target was passed:         %s ago\n' "$(format_duration "$((-REMAINING_SEC))")"
    fi
    printf '  Extra stability period:   %s\n' "$(format_duration "$SOAK_AFTER_FAILURE_SEC")"
done

echo "---------------------------------------------------------------------------------------------------------------"
printf 'Trace records skipped (multiple active subscriptions): %s\n' "$META_AMBIGUOUS"
printf 'Trace records skipped (no active subscription in lookback): %s\n' "$META_UNASSIGNED"
echo
echo "HOW TO INTERPRET THE RESULT"
echo "  - ODTS NOW is the original packet DTS shown as CURRENT DTS by the old script."
echo "  - INPUT START / INPUT NOW are reconstructed modulo-2^33 values that the"
echo "    original pts_diff() would have received. They can differ from odts when"
echo "    a transport-wide DTS offset is active."
echo "  - NEXT DTS WRAP is projected from the latest reconstructed input value."
echo "  - LEGACY PTS_UNSET is either an observed boundary crossing or a prediction"
echo "    based on the exact old pts_diff() conditions and the current ref."
echo "  - SUGGESTED END adds SOAK_AFTER_FAILURE_SEC after that crossing. For"
echo "    ref=0, it covers the next full wrap plus the same stability period."
echo "  - Dynamically added auxiliary streams (e.g. DVBSUB subtitles or secondary"
echo "    audio PIDs enabled mid-broadcast via PMT updates) and paused sparse"
echo "    subtitle streams (DVBSUB/TEXTSUB between subtitled programmes) are"
echo "    validated for reference stability and valid initial timestamps, but"
echo "    excluded from the subscription-wide minimum target so normal broadcast"
echo "    subtitle changes do not invalidate an otherwise clean long-running test."
echo "  - The subscription-wide target is the latest target among all primary streams."
echo "  - A target reached without the original failure is evidence that this"
echo "    specific regression condition was traversed successfully. It is not a"
echo "    100% proof and does not cover every stream start, restart, source error"
echo "    or client-side Timeshift behaviour. Exercise playback, pause and seeks."
echo
echo "NOTE: Re-run the script during the test. A Timeshift seek, source restart,"
echo "      reference change or input discontinuity can change the projection."
echo "      Do not use an estimate marked stale or invalid as a test completion."