#!/bin/bash
# =============================================================================
# OCI Always Free A1.Flex capacity retry
# =============================================================================
# All account, placement, networking, and retry values are loaded from .env.
# Keep .env private; it is intentionally excluded from Git.
# =============================================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
DRY_RUN_OVERRIDE="${DRY_RUN:-}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env was not found: $ENV_FILE"
  echo "Copy .env.example to .env and fill in the OCI configuration."
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# An explicit DRY_RUN=value on the command line may override .env for testing.
if [[ -n "$DRY_RUN_OVERRIDE" ]]; then
  DRY_RUN="$DRY_RUN_OVERRIDE"
fi

: "${TENANCY_NAME:?TENANCY_NAME is missing in .env}"
: "${COMPARTMENT_ID:?COMPARTMENT_ID is missing in .env}"
: "${OCI_CONFIG_FILE:?OCI_CONFIG_FILE is missing in .env}"
: "${OCI_PROFILE:?OCI_PROFILE is missing in .env}"
: "${SSH_KEY_FILE:?SSH_KEY_FILE is missing in .env}"
: "${DISPLAY_NAME:?DISPLAY_NAME is missing in .env}"
: "${SHAPE:?SHAPE is missing in .env}"
: "${OCPUS:?OCPUS is missing in .env}"
: "${MEMORY_GB:?MEMORY_GB is missing in .env}"
: "${TOTAL_OCPU_LIMIT:?TOTAL_OCPU_LIMIT is missing in .env}"
: "${TOTAL_MEMORY_LIMIT:?TOTAL_MEMORY_LIMIT is missing in .env}"
: "${SLEEP_SECONDS:?SLEEP_SECONDS is missing in .env}"
: "${MAX_RETRY_DELAY_SECONDS:?MAX_RETRY_DELAY_SECONDS is missing in .env}"
: "${CAPACITY_REQUEST_DELAY_SECONDS:?CAPACITY_REQUEST_DELAY_SECONDS is missing in .env}"
: "${OCI_READ_TIMEOUT:?OCI_READ_TIMEOUT is missing in .env}"
: "${OCI_NO_RETRY:?OCI_NO_RETRY is missing in .env}"
: "${IMAGE_OS:?IMAGE_OS is missing in .env}"
: "${IMAGE_OS_VERSION:?IMAGE_OS_VERSION is missing in .env}"
: "${ASSIGN_PUBLIC_IP:?ASSIGN_PUBLIC_IP is missing in .env}"
: "${LAUNCH_WAIT_STATE:?LAUNCH_WAIT_STATE is missing in .env}"
: "${LAUNCH_MAX_WAIT_SECONDS:?LAUNCH_MAX_WAIT_SECONDS is missing in .env}"
: "${NETWORK_RECHECK_DELAYS:?NETWORK_RECHECK_DELAYS is missing in .env}"
: "${REGION:?REGION is missing in .env}"
: "${LOCK_FILE:?LOCK_FILE is missing in .env}"
: "${ADS:?ADS is missing in .env}"

SUBNET_ID="${SUBNET_ID:-}"
IMAGE_ID="${IMAGE_ID:-}"
DRY_RUN="${DRY_RUN:-0}"
OCI_BIN="${OCI_BIN:-}"
RETRY_JITTER_SECONDS="${RETRY_JITTER_SECONDS:-0}"
LOG_TO_FILE="${LOG_TO_FILE:-1}"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_PREFIX="${LOG_PREFIX:-oci-capacity-retry}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-3}"
LOG_DAY=""
LOG_FILE=""
NTP_CHECK_ENABLED="${NTP_CHECK_ENABLED:-1}"
NTP_SERVERS="${NTP_SERVERS:-time.apple.com,pool.ntp.org}"
NTP_MAX_OFFSET_SECONDS="${NTP_MAX_OFFSET_SECONDS:-120}"
NTP_TIMEOUT_SECONDS="${NTP_TIMEOUT_SECONDS:-5}"
NTP_RETRY_DELAY_SECONDS="${NTP_RETRY_DELAY_SECONDS:-30}"
SNTP_BIN="${SNTP_BIN:-}"
IFS=',' read -r -a ADS <<< "$ADS"
IFS=',' read -r -a RECHECK_DELAYS <<< "$NETWORK_RECHECK_DELAYS"
IFS=',' read -r -a NTP_SERVER_LIST <<< "$NTP_SERVERS"

if (( ${#ADS[@]} == 0 )); then
  echo "ERROR: ADS is empty in .env."
  exit 1
fi

if [[ "$LOG_TO_FILE" != "0" && "$LOG_TO_FILE" != "1" ]]; then
  echo "ERROR: LOG_TO_FILE must be 0 or 1."
  exit 1
fi
if ! [[ "$RETRY_JITTER_SECONDS" =~ ^(0|[1-9][0-9]{0,4})$ ]] || (( RETRY_JITTER_SECONDS > 32767 )); then
  echo "ERROR: RETRY_JITTER_SECONDS must be an integer between 0 and 32767."
  exit 1
fi
if ! [[ "$LOG_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: LOG_RETENTION_DAYS must be a positive integer."
  exit 1
fi
if ! [[ "$LOG_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: LOG_PREFIX may contain only letters, numbers, dots, underscores, and hyphens."
  exit 1
fi
if [[ "$NTP_CHECK_ENABLED" != "0" && "$NTP_CHECK_ENABLED" != "1" ]]; then
  echo "ERROR: NTP_CHECK_ENABLED must be 0 or 1."
  exit 1
fi
if ! [[ "$NTP_MAX_OFFSET_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: NTP_MAX_OFFSET_SECONDS must be a positive integer."
  exit 1
fi
if ! [[ "$NTP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: NTP_TIMEOUT_SECONDS must be a positive integer."
  exit 1
fi
if ! [[ "$NTP_RETRY_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: NTP_RETRY_DELAY_SECONDS must be a positive integer."
  exit 1
fi
if [[ "$NTP_CHECK_ENABLED" == "1" ]]; then
  if [[ -z "$NTP_SERVERS" ]]; then
    echo "ERROR: NTP_SERVERS cannot be empty when NTP_CHECK_ENABLED=1."
    exit 1
  fi
  for ntp_server in "${NTP_SERVER_LIST[@]}"; do
    if [[ ! "$ntp_server" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
      echo "ERROR: Invalid NTP server name: $ntp_server"
      exit 1
    fi
  done
fi

prune_old_logs() {
  local candidate
  for candidate in "$LOG_DIR"/"${LOG_PREFIX}"-????-??-??.log; do
    [[ -f "$candidate" ]] || continue
    find "$candidate" -mtime "+$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  done
}

rotate_log_if_needed() {
  local today
  [[ "$LOG_TO_FILE" == "1" ]] || return 0

  today="$(date '+%Y-%m-%d')"
  if [[ -z "$LOG_DAY" || "$today" != "$LOG_DAY" ]]; then
    mkdir -p "$LOG_DIR" || {
      echo "ERROR: Could not create log directory: $LOG_DIR"
      exit 1
    }
    LOG_DAY="$today"
    LOG_FILE="$LOG_DIR/${LOG_PREFIX}-${LOG_DAY}.log"
    exec >> "$LOG_FILE" 2>&1
    echo "Logging to $LOG_FILE; retaining logs for $LOG_RETENTION_DAYS day(s)."
  fi

  prune_old_logs
}

rotate_log_if_needed

if [[ -f "$LOCK_FILE" ]]; then
  OLD_PID=$(cat "$LOCK_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ERROR: The script is already running (PID $OLD_PID). Stopping to avoid duplicate instances."
    exit 1
  else
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY RUN: tenancy $TENANCY_NAME | region $REGION"
  echo "DRY RUN: shape $SHAPE | ${OCPUS} OCPU / ${MEMORY_GB} GB"
  echo "DRY RUN: OCI config $OCI_CONFIG_FILE"
  printf 'DRY RUN: AD %s\n' "${ADS[@]}"
  exit 0
fi

if [[ ! -f "$OCI_CONFIG_FILE" ]]; then
  echo "ERROR: OCI config for tenancy $TENANCY_NAME was not found: $OCI_CONFIG_FILE"
  echo "Create an API key/profile and set OCI_CONFIG_FILE in .env."
  exit 1
fi

OCI_BIN="${OCI_BIN:-}"
if [[ -z "$OCI_BIN" ]]; then
  OCI_BIN="$(command -v oci 2>/dev/null || true)"
fi
if [[ -z "$OCI_BIN" && -x "/usr/local/bin/oci" ]]; then
  OCI_BIN="/usr/local/bin/oci"
fi
if [[ -z "$OCI_BIN" && -x "/opt/homebrew/bin/oci" ]]; then
  OCI_BIN="/opt/homebrew/bin/oci"
fi

if [[ -z "$OCI_BIN" ]]; then
  echo "ERROR: OCI CLI was not found in PATH."
  exit 1
fi

OCI=("$OCI_BIN" --config-file "$OCI_CONFIG_FILE" --profile "$OCI_PROFILE" --region "$REGION" --read-timeout "$OCI_READ_TIMEOUT")
if [[ "$OCI_NO_RETRY" == "1" ]]; then
  OCI+=(--no-retry)
fi
export SUPPRESS_LABEL_WARNING=True

if ! [[ "$SLEEP_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: SLEEP_SECONDS must be a positive integer."
  exit 1
fi
if ! [[ "$MAX_RETRY_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: MAX_RETRY_DELAY_SECONDS must be a positive integer."
  exit 1
fi
if ! [[ "$CAPACITY_REQUEST_DELAY_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: CAPACITY_REQUEST_DELAY_SECONDS must be a positive integer."
  exit 1
fi
if ! [[ "$OCI_READ_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: OCI_READ_TIMEOUT must be a positive integer."
  exit 1
fi
if ! [[ "$LAUNCH_MAX_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: LAUNCH_MAX_WAIT_SECONDS must be a positive integer."
  exit 1
fi
if (( MAX_RETRY_DELAY_SECONDS < SLEEP_SECONDS )); then
  MAX_RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
fi

validate_oci_access() {
  local tenancy_name output
  if ! output=$("${OCI[@]}" iam tenancy get \
      --tenancy-id "$COMPARTMENT_ID" \
      --query 'data.name' \
      --raw-output 2>&1); then
    echo "ERROR: OCI authentication or configuration for tenancy $TENANCY_NAME is invalid."
    echo "$output"
    exit 1
  fi
  tenancy_name="$output"
  if [[ -z "$tenancy_name" || "$tenancy_name" == "null" ]]; then
    echo "ERROR: OCI returned an empty tenancy name; stopping for safety."
    exit 1
  fi
  echo "OCI access confirmed for tenancy: $tenancy_name"
}

is_fatal_oci_error() {
  grep -Eqi 'NotAuthenticated|NotAuthorized|AuthenticationFailed|Authorization failed|InvalidParameter|ConfigFileNotFound|No such file or directory|401|403' <<< "$1"
}

is_capacity_error() {
  grep -Eqi 'OUT_OF_HOST_CAPACITY|OutOfHostCapacity|out of host capacity|OutOfCapacity|capacity unavailable|LimitExceeded' <<< "$1"
}

is_rate_limit_error() {
  grep -Eqi 'TooManyRequests|too many requests|Throttl|status.?[": ]+429|HTTP.?429' <<< "$1"
}

is_network_error() {
  grep -Eqi 'timed out|timeout|connection|ConnectionError|RequestException|read timeout|Max retries exceeded|ConnectTimeout' <<< "$1"
}

# OCI request signatures use the local system clock. Query public NTP servers
# as a safety check, but do not substitute their time into OCI requests.
check_ntp_clock() {
  local sntp_bin="$SNTP_BIN"
  local ntp_server ntp_output offset absolute_offset
  local unsafe_response=0

  [[ "$NTP_CHECK_ENABLED" == "1" ]] || return 0

  if [[ -z "$sntp_bin" ]]; then
    sntp_bin="$(command -v sntp 2>/dev/null || true)"
  fi
  if [[ -z "$sntp_bin" ]]; then
    echo "ERROR: sntp was not found; pausing until the system clock can be checked against public NTP."
    return 1
  fi

  for ntp_server in "${NTP_SERVER_LIST[@]}"; do
    if ntp_output=$("$sntp_bin" -t "$NTP_TIMEOUT_SECONDS" "$ntp_server" 2>&1); then
      offset="$(printf '%s\n' "$ntp_output" | awk '$1 ~ /^[+-]?[0-9]+([.][0-9]+)?$/ { print $1; exit }')"
      if [[ -z "$offset" ]]; then
        echo "WARNING: NTP server $ntp_server returned an unreadable offset."
        continue
      fi

      absolute_offset="$(awk -v value="$offset" 'BEGIN { if (value < 0) value = -value; print value }')"
      if awk -v offset="$absolute_offset" -v maximum="$NTP_MAX_OFFSET_SECONDS" 'BEGIN { exit !(offset <= maximum) }'; then
        echo "NTP check passed: $ntp_server; measured offset ${offset}s."
        return 0
      fi

      unsafe_response=1
      echo "WARNING: System clock offset is ${offset}s according to $ntp_server; trying the next NTP server."
      continue
    fi

    echo "WARNING: NTP server $ntp_server could not be reached: $(printf '%s\n' "$ntp_output" | head -1)"
  done

  if (( unsafe_response )); then
    echo "ERROR: No configured NTP server reported a safe clock offset."
  else
    echo "ERROR: No configured NTP server responded with a readable clock offset."
  fi
  return 1
}

wait_for_ntp_clock() {
  while ! check_ntp_clock; do
    echo "WARNING: NTP is not currently safe; keeping the script alive and retrying in ${NTP_RETRY_DELAY_SECONDS}s."
    sleep "$NTP_RETRY_DELAY_SECONDS"
  done
}

wait_for_ntp_clock
validate_oci_access

get_resource_id() {
  local kind="$1"
  local value

  if [[ "$kind" == "subnet" ]]; then
    if ! value=$("${OCI[@]}" network subnet list \
      --compartment-id "$COMPARTMENT_ID" \
      --display-name "$SUBNET_NAME" \
      --all \
      --query 'data[?"lifecycle-state"==`AVAILABLE`].id | [0]' \
      --raw-output); then
      return 1
    fi
  else
    if ! value=$("${OCI[@]}" compute image list \
      --compartment-id "$COMPARTMENT_ID" \
      --operating-system "$IMAGE_OS" \
      --operating-system-version "$IMAGE_OS_VERSION" \
      --shape "$SHAPE" \
      --sort-by TIMECREATED \
      --sort-order DESC \
      --all \
      --query 'data[?"lifecycle-state"==`AVAILABLE`].id | [0]' \
      --raw-output); then
      return 1
    fi
  fi

  printf '%s' "$value"
}

if [[ -z "$SUBNET_ID" ]]; then
  SUBNET_ID=$(get_resource_id subnet)
fi
if [[ -z "$IMAGE_ID" ]]; then
  IMAGE_ID=$(get_resource_id image)
fi

if [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "null" ]]; then
  echo "ERROR: No available subnet was found in the root compartment."
  exit 1
fi
if [[ -z "$IMAGE_ID" || "$IMAGE_ID" == "null" ]]; then
  echo "ERROR: No available Oracle Linux 9 image was found for A1.Flex."
  exit 1
fi

if [[ ! -f "$SSH_KEY_FILE" ]]; then
  echo "ERROR: SSH public key was not found at $SSH_KEY_FILE"
  exit 1
fi

# --- Notification (macOS pop-up + sound, optional Bark push) ---
notify() {
  local title="$1"
  local message="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${message}\" with title \"${title}\" sound name \"Glass\"" 2>/dev/null
  fi
  if [[ -n "${BARK_KEY:-}" ]]; then
    python3 "$SCRIPT_DIR/bark_push.py" "$title" "$message" || true
  fi
  echo "[NOTIFICATION] ${title}: ${message}"
}

# --- Check the capacity report before a launch attempt ---
check_capacity() {
  local availability_domain="$1"
  "${OCI[@]}" compute compute-capacity-report create \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$availability_domain" \
    --shape-availabilities "[{\"instanceShape\":\"$SHAPE\",\"instanceShapeConfig\":{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}}]" \
    --query 'data."shape-availabilities"[0]."availability-status"' \
    --raw-output
}

# --- Sum OCPU and memory for all non-terminated A1.Flex instances in the compartment ---
get_total_usage() {
  "${OCI[@]}" compute instance list \
    --compartment-id "$COMPARTMENT_ID" \
    --all \
    --query "data[?shape=='$SHAPE' && \"lifecycle-state\" != 'TERMINATED' && \"lifecycle-state\" != 'TERMINATING'].{ocpus:\"shape-config\".ocpus, mem:\"shape-config\".\"memory-in-gbs\"}" \
    --raw-output
}

check_totals() {
  local json
  if ! json=$(get_total_usage); then
    return 1
  fi
  if [[ -z "$json" || "$json" == "null" ]]; then
    echo "0 0"
    return
  fi
  local total_ocpu total_mem
  total_ocpu=$(echo "$json" | python3 -c "import json,sys; data=json.load(sys.stdin); print(sum(d.get('ocpus',0) or 0 for d in data))" 2>/dev/null)
  total_mem=$(echo "$json" | python3 -c "import json,sys; data=json.load(sys.stdin); print(sum(d.get('mem',0) or 0 for d in data))" 2>/dev/null)
  echo "${total_ocpu:-0} ${total_mem:-0}"
}

echo "=========================================="
echo "Starting automatic A1.Flex retry ($OCPUS OCPU / ${MEMORY_GB}GB per attempt)"
echo "Total target: $TOTAL_OCPU_LIMIT OCPU / ${TOTAL_MEMORY_LIMIT}GB (sum of all A1 instances)"
echo "Region: $REGION | Delay: ${SLEEP_SECONDS}s | Capacity-call delay: ${CAPACITY_REQUEST_DELAY_SECONDS}s | Stop with Ctrl+C"
echo "=========================================="

target_reached() {
  local current_ocpu="$1"
  local current_mem="$2"
  (( $(echo "$current_ocpu >= $TOTAL_OCPU_LIMIT" | bc -l 2>/dev/null || echo 0) )) || \
    (( $(echo "$current_mem >= $TOTAL_MEMORY_LIMIT" | bc -l 2>/dev/null || echo 0) ))
}

# Jitter changes the actual wait, not the base used by exponential backoff.
# Bash RANDOM returns 0..32767, matching the validated jitter range.
set_cycle_delay() {
  local base_delay="$1"
  CYCLE_DELAY_SECONDS=$(( base_delay + RANDOM % (RETRY_JITTER_SECONDS + 1) ))
}

attempt=0
RETRY_DELAY_SECONDS="$SLEEP_SECONDS"

while true; do
  rotate_log_if_needed

  if ! check_ntp_clock; then
    echo "[$(date '+%H:%M:%S')] WARNING: NTP is not currently safe; pausing OCI calls and retrying in ${NTP_RETRY_DELAY_SECONDS}s."
    sleep "$NTP_RETRY_DELAY_SECONDS"
    continue
  fi

  if ! CURRENT_TOTALS="$(check_totals)"; then
    echo "[$(date '+%H:%M:%S')] ERROR: Cannot check existing A1.Flex instances; stopping to avoid a duplicate."
    notify "Oracle Cloud - ERROR" "The existing-instance check failed. The script was stopped."
    exit 1
  fi
  read -r CUR_OCPU CUR_MEM <<< "$CURRENT_TOTALS"
  CUR_OCPU="${CUR_OCPU:-0}"
  CUR_MEM="${CUR_MEM:-0}"

  echo "[$(date '+%H:%M:%S')] Current total: ${CUR_OCPU} OCPU / ${CUR_MEM}GB (target: ${TOTAL_OCPU_LIMIT}/${TOTAL_MEMORY_LIMIT})"

  if target_reached "$CUR_OCPU" "$CUR_MEM"; then
    echo "=========================================="
    echo "TARGET REACHED! Total usage of ${CUR_OCPU} OCPU / ${CUR_MEM}GB is at or above the limit."
    echo "Stopping the script; no additional instances will be created."
    echo "=========================================="
    notify "Oracle Cloud - Complete" "Limit reached: ${CUR_OCPU} OCPU / ${CUR_MEM}GB. The script was stopped."
    exit 0
  fi

  cycle_had_capacity=0
  cycle_had_error=0
  cycle_had_rate_limit=0
  launch_succeeded=0
  launch_uncertain=0
  capacity_checks=0

  # Check every AD without waiting between them; wait only after the full cycle.
  for ad_suffix in "${ADS[@]}"; do
    attempt=$((attempt + 1))
    AD_FULL="$ad_suffix"

    if (( capacity_checks > 0 )); then
      sleep "$CAPACITY_REQUEST_DELAY_SECONDS"
    fi
    capacity_checks=$((capacity_checks + 1))

    CAPACITY_OUTPUT="$(check_capacity "$AD_FULL" 2>&1)"
    CAPACITY_EXIT=$?
    CAPACITY_STATUS="$(printf '%s\n' "$CAPACITY_OUTPUT" | awk 'NF { line=$0 } END { print line }' | tr -d '\r')"

    if (( CAPACITY_EXIT != 0 )); then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: capacity report failed:"
      echo "$CAPACITY_OUTPUT" | head -20
      if is_rate_limit_error "$CAPACITY_OUTPUT"; then
        echo "[$(date '+%H:%M:%S')] OCI rate limit; increasing the delay before the next cycle."
        cycle_had_rate_limit=1
      elif is_fatal_oci_error "$CAPACITY_OUTPUT"; then
        notify "Oracle Cloud - ERROR" "The script was stopped because of OCI authentication or configuration."
        exit 1
      else
        cycle_had_error=1
      fi
      continue
    fi

    if [[ "$CAPACITY_STATUS" == "OUT_OF_HOST_CAPACITY" ]]; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: no capacity according to the capacity report."
      cycle_had_capacity=1
      continue
    fi
    if [[ "$CAPACITY_STATUS" != "AVAILABLE" ]]; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: capacity status=${CAPACITY_STATUS:-UNKNOWN}; skipping launch."
      cycle_had_error=1
      continue
    fi

    echo "[$(date '+%H:%M:%S')] Attempt #${attempt} - ${AD_FULL} (capacity AVAILABLE) ..."

    RESULT="$("${OCI[@]}" compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$AD_FULL" \
      --shape "$SHAPE" \
      --shape-config "{\"ocpus\": ${OCPUS}, \"memoryInGBs\": ${MEMORY_GB}}" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip "$ASSIGN_PUBLIC_IP" \
      --display-name "$DISPLAY_NAME" \
      --ssh-authorized-keys-file "$SSH_KEY_FILE" \
      --wait-for-state "$LAUNCH_WAIT_STATE" \
      --max-wait-seconds "$LAUNCH_MAX_WAIT_SECONDS" \
      --query 'data.id' \
      --raw-output \
      2>&1)"
    LAUNCH_EXIT=$?
    INSTANCE_ID="$(printf '%s\n' "$RESULT" | grep -Eo 'ocid1\.instance\.[A-Za-z0-9._-]+' | tail -n 1)"

    if (( LAUNCH_EXIT == 0 )); then
      if [[ -z "$INSTANCE_ID" ]]; then
        echo "[$(date '+%H:%M:%S')] OCI launch finished without an instance OCID; no blind second launch will be attempted."
        echo "$RESULT" | head -20
        launch_uncertain=1
        break
      fi

      echo ""
      echo "=========================================="
      echo "SUCCESS! The instance is RUNNING in ${AD_FULL} after ${attempt} attempts."
      echo "Instance OCID: $INSTANCE_ID"
      echo "=========================================="
      notify "Oracle Cloud - Instance created" "New instance in ${AD_FULL} (${OCPUS} OCPU/${MEMORY_GB}GB)."

      if ! NEW_TOTALS="$(check_totals)"; then
        echo "[$(date '+%H:%M:%S')] The instance was created, but the follow-up usage check failed."
        notify "Oracle Cloud - Check manually" "The instance was created, but the follow-up usage check failed."
        exit 1
      fi
      read -r NEW_OCPU NEW_MEM <<< "$NEW_TOTALS"
      NEW_OCPU="${NEW_OCPU:-0}"
      NEW_MEM="${NEW_MEM:-0}"
      echo "[$(date '+%H:%M:%S')] New total: ${NEW_OCPU} OCPU / ${NEW_MEM}GB"

      if target_reached "$NEW_OCPU" "$NEW_MEM"; then
        echo "Total target reached. Stopping the script."
        notify "Oracle Cloud - Complete" "Total usage is ${NEW_OCPU} OCPU / ${NEW_MEM}GB. Target reached; the script was stopped."
        exit 0
      fi

      echo "The target is not complete yet (${NEW_OCPU}/${TOTAL_OCPU_LIMIT} OCPU); continuing after refresh."
      launch_succeeded=1
      break
    fi

    if is_fatal_oci_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] Serious OCI error in ${AD_FULL}:"
      echo "$RESULT" | head -20
      notify "Oracle Cloud - ERROR" "The script was stopped because of OCI authentication or configuration."
      exit 1
    elif is_rate_limit_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: OCI rate limit during the launch request."
      cycle_had_rate_limit=1
    elif is_capacity_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: launch did not receive capacity. Continuing..."
      cycle_had_capacity=1
    elif is_network_error "$RESULT"; then
      echo "[$(date '+%H:%M:%S')] ${AD_FULL}: network problem after the launch request. Checking whether an instance exists..."
      for recheck_delay in "${RECHECK_DELAYS[@]}"; do
        sleep "$recheck_delay"
        if ! RECHECK_TOTALS="$(check_totals)"; then
          echo "[$(date '+%H:%M:%S')] Cannot confirm the state after the network error; no second launch will be attempted."
          launch_uncertain=1
          break
        fi
        read -r RECHECK_OCPU RECHECK_MEM <<< "$RECHECK_TOTALS"
        RECHECK_OCPU="${RECHECK_OCPU:-0}"
        RECHECK_MEM="${RECHECK_MEM:-0}"
        if target_reached "$RECHECK_OCPU" "$RECHECK_MEM" || \
           (( $(echo "$RECHECK_OCPU > $CUR_OCPU" | bc -l 2>/dev/null || echo 0) )); then
          echo "The instance WAS created despite the network error. Stopping."
          notify "Oracle Cloud - Instance created" "An instance was created despite the network error in ${AD_FULL}."
          exit 0
        fi
      done
      if (( launch_uncertain == 0 )); then
        echo "[$(date '+%H:%M:%S')] The instance was not confirmed; waiting before another launch attempt."
        launch_uncertain=1
      fi
      break
    else
      echo "[$(date '+%H:%M:%S')] Unknown OCI response in ${AD_FULL}; treating it as a temporary error:"
      echo "$RESULT" | head -10
      cycle_had_error=1
    fi
  done

  if (( launch_uncertain )); then
    RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
    set_cycle_delay "$RETRY_DELAY_SECONDS"
    echo "[$(date '+%H:%M:%S')] Waiting ${CYCLE_DELAY_SECONDS}s before checking the uncertain launch request again..."
    sleep "$CYCLE_DELAY_SECONDS"
    continue
  fi

  if (( launch_succeeded )); then
    RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
    set_cycle_delay "$RETRY_DELAY_SECONDS"
    echo "[$(date '+%H:%M:%S')] Waiting ${CYCLE_DELAY_SECONDS}s before refreshing usage after the successful launch."
    sleep "$CYCLE_DELAY_SECONDS"
    continue
  fi

  if (( cycle_had_rate_limit )); then
    RETRY_DELAY_SECONDS=$(( RETRY_DELAY_SECONDS * 2 ))
    if (( RETRY_DELAY_SECONDS > MAX_RETRY_DELAY_SECONDS )); then
      RETRY_DELAY_SECONDS="$MAX_RETRY_DELAY_SECONDS"
    fi
    set_cycle_delay "$RETRY_DELAY_SECONDS"
    echo "[$(date '+%H:%M:%S')] OCI rate limit; waiting ${CYCLE_DELAY_SECONDS}s before the next cycle."
    sleep "$CYCLE_DELAY_SECONDS"
    continue
  fi

  if (( cycle_had_error )); then
    RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
    set_cycle_delay "$RETRY_DELAY_SECONDS"
    echo "[$(date '+%H:%M:%S')] The cycle had an error; retrying in ${CYCLE_DELAY_SECONDS}s."
    sleep "$CYCLE_DELAY_SECONDS"
    continue
  fi

  if (( cycle_had_capacity )); then
    set_cycle_delay "$RETRY_DELAY_SECONDS"
    echo "[$(date '+%H:%M:%S')] All checked zones are out of capacity. Waiting ${CYCLE_DELAY_SECONDS}s before the next cycle."
    sleep "$CYCLE_DELAY_SECONDS"
    if (( RETRY_DELAY_SECONDS < MAX_RETRY_DELAY_SECONDS )); then
      RETRY_DELAY_SECONDS=$(( RETRY_DELAY_SECONDS * 2 ))
      if (( RETRY_DELAY_SECONDS > MAX_RETRY_DELAY_SECONDS )); then
        RETRY_DELAY_SECONDS="$MAX_RETRY_DELAY_SECONDS"
      fi
    fi
    continue
  fi

  RETRY_DELAY_SECONDS="$SLEEP_SECONDS"
  set_cycle_delay "$RETRY_DELAY_SECONDS"
  echo "[$(date '+%H:%M:%S')] Waiting ${CYCLE_DELAY_SECONDS}s before the next cycle."
  sleep "$CYCLE_DELAY_SECONDS"
done
