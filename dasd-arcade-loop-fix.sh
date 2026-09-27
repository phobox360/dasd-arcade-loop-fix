#!/usr/bin/env bash
#===============================================================================
#  dasd-arcade-loop-fix.sh
#
#  Fixes the wedged Apple Arcade background task that makes `dasd` churn
#  continuously with no timeout on macOS 27.0.
#
#  ---------------------------------------------------------------------------
#  WHAT YOU ARE SEEING
#    - `dasd` pinned around 2.3-2.6% of one CPU core, indefinitely
#    - `dasd` + `appstoreagent` emitting 50-78% of ALL unified-log volume
#    - `logd` logging:  Quarantined: /usr/libexec/dasd
#
#  WHY (root cause, confirmed from `log show` output)
#    The DAS activity  "501:com.apple.appstored.ArcadeResetPO"  (internal name
#    ArcadePayoutReset) is executed by `appstoreagent`.  On its weekly reset
#    boundary it computes the NEXT run time as "= ArcadePayoutResetDate",
#    WITHOUT applying the interval -- its healthy sibling tasks log
#    "with interval: 21600"/"43200"; this one logs no interval at all.
#
#    Related tasks submit a real future scheduling window.
#    while the broken one submits a ZERO-WIDTH window in the PAST.
#
#    DAS therefore treats the activity as permanently overdue, logs
#    "Running <private> immediately on submission", completes it, the agent
#    resubmits it, and the loop repeats ~150x/second.
#
#  THE FIX
#    Advance ArcadePayoutResetDate by one week.  The computed next-run window
#    then lands in the future, so DAS stops treating the activity as overdue
#    and the loop ends.
#
#    NOTE: this stops the CURRENT episode.  The upstream bug still fails to
#    advance the date, so it will almost certainly recur at the next weekly
#    boundary (Sunday 00:00 local).  Use --durable to suppress it outright.
#
#  STRICTLY REVERSIBLE.  `--rollback` restores the original value.
#===============================================================================

set -uo pipefail

VERSION="1.0.0"
PREF_DOMAIN="com.apple.appstored"
PREF_KEY="ArcadePayoutResetDate"
AGENT_LABEL="com.apple.appstoreagent"
DAEMON_LABEL="com.apple.appstored"
TASK_NAME="com.apple.appstored.ArcadeResetPO"

# Duration of the Arcade payout reset cycle (weekly).  Advance by exactly this
# much so we land on the next occurrence of the same weekly boundary.
CYCLE_SECONDS=$((7 * 24 * 60 * 60))
DURABLE_DATE="2035-01-01 00:00:00 +0000"

# ---- modes ------------------------------------------------------------------
MODE="apply"        # apply | dryrun | rollback
ASSUME_YES=0
DURABLE=0
LOGFILE=""
BACKUP_DIR=""
DEFAULT_BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/dasd-arcade-fix-backups"

# ---- exit codes -------------------------------------------------------------
E_PREFLIGHT=1
E_STATE=2
E_WRITE=3
E_VERIFY=4
E_ABORT=5
E_ROLLBACK=6

# ---- cosmetics --------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_DIM=''; C_RST=''
fi

say()  { printf '%s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
hr()   { printf '%s\n' "--------------------------------------------------------------------------"; }
ok()   { printf '%s\n' "${C_GRN}[ OK ]${C_RST} $*"; }
warn() { printf '%s\n' "${C_YEL}[WARN]${C_RST} $*"; }
bad()  { printf '%s\n' "${C_RED}[FAIL]${C_RST} $*"; }
note() { printf '%s\n' "${C_DIM}$*${C_RST}"; }

step() {
  hr
  printf '%s\n' "${C_BLD}${C_BLU}STEP $1${C_RST} ${C_BLD}$2${C_RST}"
  hr
}

die() { local c="$1"; shift; printf '\n%s\n' "${C_RED}${C_BLD}ABORTED:${C_RST} $*"; exit "$c"; }

# NOTE: quoted heredoc ('EOF') on purpose. An unquoted heredoc would execute
# the backticks in this text as command substitutions.
usage() {
  cat <<'EOF'
dasd-arcade-loop-fix.sh v1.0.0

Stops the wedged ArcadePayoutReset task (DAS activity
"com.apple.appstored.ArcadeResetPO") that makes dasd churn forever.

USAGE
  dasd-arcade-loop-fix.sh [options]

MODES
  (default)        Show plan, prompt for confirmation, then apply.
  --dry-run        Show everything, change NOTHING. Safe. Start here.
  --rollback       Restore the original ArcadePayoutResetDate.
  --yes, -y        Do not prompt (for scripted use).

OPTIONS
  --durable        Instead of "next week", set the date to
                   2035-01-01 00:00:00 +0000
                   so the task never comes due again. Stops it permanently.
  --log FILE       Also write all output to FILE.
  --backup-dir DIR Where to keep the backup + saved original.
                   Default: ./dasd-arcade-fix-backups next to this script.
  -h, --help       This help.

EXIT CODES
  0 success   1 preflight failed   2 could not read state   3 write failed
  4 verification failed   5 aborted by user   6 rollback failed

NOTES
  * Must NOT be run with sudo. The preference is per-user; as root it would
    be written to root's home and silently do nothing.
  * No sudo is needed for anything this script does.
  * Only com.apple.appstored / ArcadePayoutResetDate is modified, plus a
    restart of the user agent com.apple.appstoreagent.
  * A timestamped backup of the whole preference file is always taken first.
  * Measure success by CPU usage, NOT by log volume: logd suppresses
    dasd/appstoreagent logging once it quarantines them.
EOF
}

#===============================================================================
# arg parsing
#===============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|--dryrun|-n) MODE="dryrun" ;;
    --apply)               MODE="apply" ;;
    --rollback)            MODE="rollback" ;;
    --durable|--permanent) DURABLE=1 ;;
    -y|--yes)              ASSUME_YES=1 ;;
    --log)                 shift; LOGFILE="${1:-}" ;;
    --log=*)               LOGFILE="${1#*=}" ;;
    --backup-dir)          shift; BACKUP_DIR="${1:-}" ;;
    --backup-dir=*)        BACKUP_DIR="${1#*=}" ;;
    -h|--help)             usage; exit 0 ;;
    *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "$BACKUP_DIR" ]] || BACKUP_DIR="$DEFAULT_BACKUP_DIR"

if [[ -n "$LOGFILE" ]]; then
  if ! : >>"$LOGFILE" 2>/dev/null; then
    printf 'Cannot write log file: %s\n' "$LOGFILE" >&2; exit "$E_PREFLIGHT"
  fi
  exec > >(tee -a "$LOGFILE") 2>&1
fi

#===============================================================================
# helpers
#===============================================================================

# All date maths is done with TZ pinned to UTC.  This matters: BSD `date`
# silently parses "%Y-%m-%dT%H:%M:%SZ" as LOCAL time, which shifts the result
# by the local UTC offset.  The "%z"/"%Y-%m-%d %H:%M:%S +0000" forms are
# honoured correctly and are what we use.
to_epoch() {  # echo epoch seconds, or empty on failure
  local s="$1" e
  e=$(TZ=UTC0 date -j -f "%Y-%m-%d %H:%M:%S %z" "$s" +%s 2>/dev/null) && [[ -n "$e" ]] && { echo "$e"; return 0; }
  e=$(TZ=UTC0 date -j -f "%Y-%m-%d %H:%M:%S +0000" "$s" +%s 2>/dev/null) && [[ -n "$e" ]] && { echo "$e"; return 0; }
  # ISO-8601 Zulu, as emitted by `plutil -extract ... raw` for a <date>.
  e=$(TZ=UTC0 date -j -f "%Y-%m-%dT%H:%M:%SZ" "$s" +%s 2>/dev/null) && [[ -n "$e" ]] && { echo "$e"; return 0; }
  return 1
}

from_epoch() { TZ=UTC0 date -r "$1" "+%Y-%m-%d %H:%M:%S %z" 2>/dev/null; }

# epoch -> a human-readable date in local time
human_local() { date -r "$1" "+%A %Y-%m-%d %H:%M %z" 2>/dev/null; }

# Read the stored date in a locale-independent form.
#
# `defaults read` renders an NSDate through the user's AppleLocale, so on a
# 12-hour locale it prints e.g. "2026-09-26 10:00:00 PM +0000" -- and since
# macOS 14 the separator before AM/PM is U+202F NARROW NO-BREAK SPACE, not an
# ASCII space. BSD `date -j -f` cannot parse either, so to_epoch() fails and
# the script aborts at STEP 2 with "Unparsable current value". Setting LC_ALL
# does not help: the formatting is done by CFDateFormatter, not libc.
#
# `plutil -extract ... raw` always emits ISO-8601 Zulu, independent of locale.
read_pref() {
  local plist="$HOME/Library/Preferences/${PREF_DOMAIN}.plist" v
  v=$(plutil -extract "$PREF_KEY" raw -o - "$plist" 2>/dev/null) \
    && [[ -n "$v" ]] && { printf '%s\n' "$v"; return 0; }
  defaults read "$PREF_DOMAIN" "$PREF_KEY" 2>/dev/null
}

# Report the stored plist type: date / string / integer / missing
pref_type() {
  local plist="$HOME/Library/Preferences/${PREF_DOMAIN}.plist"
  [[ -f "$plist" ]] || { echo "missing-plist"; return; }
  local xml
  xml=$(plutil -convert xml1 -o - "$plist" 2>/dev/null) || { echo "unreadable"; return; }
  if printf '%s\n' "$xml" | grep -A1 -- "<key>${PREF_KEY}</key>" | grep -q '<date>';   then echo "date";   return; fi
  if printf '%s\n' "$xml" | grep -A1 -- "<key>${PREF_KEY}</key>" | grep -q '<string>'; then echo "string"; return; fi
  if printf '%s\n' "$xml" | grep -A1 -- "<key>${PREF_KEY}</key>" | grep -q '<integer\|<real'; then echo "number"; return; fi
  if printf '%s\n' "$xml" | grep -q -- "<key>${PREF_KEY}</key>"; then echo "other"; return; fi
  echo "absent"
}

# CPU % of one core for a process, from `top` (2 samples; 2nd is meaningful).
# `ps` is NOT usable here: its %cpu is the lifetime average, which barely moves
# for a daemon that has been up for hours.
proc_cpu() {
  local name="$1" out v
  command -v top >/dev/null 2>&1 || { echo "top-unavailable"; return 1; }
  out=$(top -l 2 -o cpu -n 100 -stats pid,command,cpu 2>/dev/null) || { echo "top-failed"; return 1; }
  [[ -z "$out" ]] && { echo "top-empty"; return 1; }
  v=$(printf '%s\n' "$out" | awk -v n="$name" '$2==n {v=$3} END {print v}')
  if [[ -z "$v" ]]; then echo "not-shown"; return 2; fi
  echo "$v"
}

pid_of() { pgrep -x "$1" 2>/dev/null | head -1; }

# Render a proc_cpu result for humans (proc_cpu's raw value is still used for
# the pass/fail logic; this is display only).
fmt_cpu() {
  case "$1" in
    ''|n/a|unknown)   echo "unavailable" ;;
    top-unavailable)  echo "unavailable (no 'top' binary)" ;;
    top-failed)       echo "unavailable ('top' could not run)" ;;
    top-empty)        echo "unavailable ('top' returned nothing)" ;;
    not-shown)        echo "idle (below the top-100 cutoff)" ;;
    *)                echo "$1%" ;;
  esac
}

agent_pids() { pgrep -x "appstoreagent" 2>/dev/null | tr '\n' ' '; }

#===============================================================================
# BANNER + PREFLIGHT
#===============================================================================
say ""
say "${C_BLD}dasd-arcade-loop-fix.sh${C_RST}  v${VERSION}"
say "Fixes the wedged ArcadePayoutReset DAS activity making dasd churn."
say ""

step 1 "PREFLIGHT - environment and tool checks"

say "  Context:"
info "Date/time now    : $(date '+%A %Y-%m-%d %H:%M:%S %z')"
info "UTC now          : $(TZ=UTC0 date '+%Y-%m-%d %H:%M:%S %z')"
info "macOS product    : $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) (build $(sw_vers -buildVersion 2>/dev/null))"
info "Mode             : ${MODE}$( ((DURABLE)) && printf ' + durable' )"
info "Backup dir       : ${BACKUP_DIR}"
[[ -n "$LOGFILE" ]] && info "Log file         : ${LOGFILE}"
say ""

say "  Tool availability:"
PREFLIGHT_FAIL=0
for t in defaults plutil launchctl pgrep top date awk grep; do
  if command -v "$t" >/dev/null 2>&1; then
    info "$(printf '%-10s' "$t") present  ($(command -v "$t"))"
  else
    info "$(printf '%-10s' "$t") ${C_RED}MISSING${C_RST}"
    PREFLIGHT_FAIL=1
  fi
done
[[ $PREFLIGHT_FAIL -eq 1 ]] && die $E_PREFLIGHT "required tool(s) missing."
ok "All required tools present."
say ""

say "  Safety checks:"
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  bad "Running as root (EUID 0)."
  note "    The preference is per-user. As root it would be written to root's"
  note "    home (~/Library/Preferences of /var/root) and have no effect on the"
  note "    logged-in user's App Store agent."
  die $E_PREFLIGHT "Re-run WITHOUT sudo, as your normal user account."
fi
ok "Not running as root (correct)."
[[ -d "$HOME/Library/Preferences" ]] || die $E_PREFLIGHT "No ~/Library/Preferences directory."
ok "$HOME/Library/Preferences exists."
info "Preference file  : $HOME/Library/Preferences/${PREF_DOMAIN}.plist"

if [[ -f "$HOME/Library/Preferences/${PREF_DOMAIN}.plist" ]]; then
  ls -l "$HOME/Library/Preferences/${PREF_DOMAIN}.plist" | sed 's/^/    /'
else
  die $E_STATE "Preference file for ${PREF_DOMAIN} not found."
fi

if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
  ok "GUI launchd domain gui/$(id -u) reachable."
else
  warn "Could not query gui/$(id -u); agent restart may need the fallback path."
fi
say ""

#===============================================================================
# STEP 2 - capture current state
#===============================================================================
step 2 "CURRENT STATE - what the system looks like right now"

CUR_RAW="$(read_pref)"
CUR_TYPE="$(pref_type)"

say "  ${PREF_DOMAIN} / ${PREF_KEY}:"
info "raw value (defaults) : ${CUR_RAW:-<empty>}"
info "stored plist type    : ${CUR_TYPE}"
say ""

if [[ -z "$CUR_RAW" ]]; then
  bad "Could not read ${PREF_KEY} from ${PREF_DOMAIN}."
  note "    This key may not exist on your system (e.g. no Arcade"
  note "    history). Without it the script cannot compute a target date."
  if [[ "$MODE" == "rollback" ]]; then
    note "    Rollback still possible from a saved original, see below."
  else
    die $E_STATE "Cannot continue: no current value to advance."
  fi
fi

# stored value -> epoch
CUR_EPOCH="$([[ -n "$CUR_RAW" ]] && to_epoch "$CUR_RAW" || true)"
if [[ -n "$CUR_RAW" && -z "$CUR_EPOCH" ]]; then
  bad "Could not parse '${CUR_RAW}' as a date."
  note "    Expected a form like: YYYY-MM-DD HH:MM:SS +0000"
  die $E_STATE "Unparsable current value; refusing to guess."
fi

if [[ -n "$CUR_EPOCH" ]]; then
  NOW_EPOCH=$(date +%s)
  AGE=$((NOW_EPOCH - CUR_EPOCH))
  info "as epoch (UTC)       : ${CUR_EPOCH}"
  info "as local time        : $(human_local "$CUR_EPOCH")"
  info "age                  : ${AGE}s ago  ($(( AGE / 3600 ))h $(( (AGE % 3600) / 60 ))m)"
  if [[ $AGE -gt 0 ]]; then
    warn "The stored reset date is IN THE PAST. This is exactly the condition"
    note "    that makes the task permanently overdue and loops it."
  else
    ok "The stored reset date is in the future - the loop should already be idle."
  fi
fi
say ""

# live daemon state
say "  Live process state:"
DASD_PID="$(pid_of dasd)"
ASA_PID_BEFORE="$(pid_of appstoreagent)"
AST_PID="$(pid_of appstored)"
info "dasd            pid : ${DASD_PID:-<not running>}"
info "appstoreagent   pid : ${ASA_PID_BEFORE:-<not running>}"
info "appstored       pid : ${AST_PID:-<not running>}"
info "all appstoreagent   : $(agent_pids)"
say ""

say "  launchd run-state (a crash/restart loop would show runs > 1):"
for svc in "system/${DAEMON_LABEL}" "gui/$(id -u)/${AGENT_LABEL}"; do
  st=$(launchctl print "$svc" 2>/dev/null | awk -F'= ' '/^[[:space:]]*state =/{print $2; exit}')
  rn=$(launchctl print "$svc" 2>/dev/null | awk -F'= ' '/^[[:space:]]*runs =/{print $2; exit}')
  pd=$(launchctl print "$svc" 2>/dev/null | awk -F'= ' '/^[[:space:]]*pid =/{print $2; exit}')
  ex=$(launchctl print "$svc" 2>/dev/null | awk -F'= ' '/last exit code/{print $2; exit}')
  info "$(printf '%-46s' "$svc") state=${st:-?} runs=${rn:-?} pid=${pd:-?} lastExit=${ex:-?}"
done
say ""

say "  ${C_BLD}CPU baseline${C_RST} (this is the real signal - logd suppresses the"
say "  daemons' log output once it quarantines them, so logs become useless):"
DASD_CPU_BEFORE="$(proc_cpu dasd)"
ASA_CPU_BEFORE="$(proc_cpu appstoreagent)"
info "dasd           : $(fmt_cpu "$DASD_CPU_BEFORE") of one core"
info "appstoreagent  : $(fmt_cpu "$ASA_CPU_BEFORE") of one core"
note "    Reference: dasd idles around 0.00-0.05%.  A value near 2.3-2.6%"
note "    means the loop is running.  'not-shown' means it is below the"
note "    top-100 cutoff, i.e. effectively idle."
say ""

say "  Recent logd quarantine evidence (why the logs went quiet):"
if [[ -r /private/var/db/diagnostics/logd.0.log ]]; then
  q=$(grep -i "Quarantined" /private/var/db/diagnostics/logd.0.log 2>/dev/null | tail -6)
  if [[ -n "$q" ]]; then printf '%s\n' "$q" | sed 's/^/    /'; else info "(no quarantine lines readable)"; fi
else
  info "(logd log not readable - skipping; this is cosmetic only)"
fi
say ""

#===============================================================================
# ROLLBACK MODE
#===============================================================================
if [[ "$MODE" == "rollback" ]]; then
  step 3 "ROLLBACK - restore the original ArcadePayoutResetDate"

  ORIG_FILE="${BACKUP_DIR}/original-date.txt"
  ORIG_VAL=""
  if [[ -f "$ORIG_FILE" ]]; then
    ORIG_VAL=$(head -1 "$ORIG_FILE")
    ok "Found saved original: ${ORIG_VAL}"
    info "from ${ORIG_FILE}"
  else
    warn "No saved original at ${ORIG_FILE}"
    if [[ -n "$BACKUP_DIR" ]] && compgen -G "${BACKUP_DIR}/*.plist.bak" >/dev/null 2>&1; then
      latest=$(ls -t "${BACKUP_DIR}"/*.plist.bak 2>/dev/null | head -1)
      info "Found plist backup: ${latest}"
      ORIG_VAL=$(plutil -convert xml1 -o - "$latest" 2>/dev/null \
                 | grep -A1 "<key>${PREF_KEY}</key>" | grep -o '<date>[^<]*</date>' \
                 | sed 's/<[^>]*>//g' | sed 's/T/ /; s/Z$//; s/$/ +0000/')
      [[ -n "$ORIG_VAL" ]] && ok "Recovered original from backup: ${ORIG_VAL}"
    fi
  fi

  if [[ -z "$ORIG_VAL" ]]; then
    bad "Cannot determine the original value."
    note "    Restore manually:  plutil -p ${BACKUP_DIR}/*.plist.bak"
    die $E_ROLLBACK "Nothing to roll back to."
  fi

  say ""
  say "  Will restore: ${C_BLD}${ORIG_VAL}${C_RST}"
  say "  (currently  : ${CUR_RAW})"
  say ""

  if (( ! ASSUME_YES )); then
    if [[ ! -t 0 ]]; then
      die $E_ABORT "stdin is not a terminal; re-run with --yes to confirm."
    fi
    read -r -p "  Proceed with rollback? [y/N] " a
    case "$a" in y|Y|yes|YES) ;; *) die $E_ABORT "Rollback cancelled by user." ;; esac
  fi

  if defaults write "$PREF_DOMAIN" "$PREF_KEY" -date "$ORIG_VAL" 2>/dev/null; then
    NEW_RAW="$(read_pref)"
    ok "Restored. Value now: ${NEW_RAW}"
  else
    die $E_ROLLBACK "defaults write failed."
  fi

  info "Restarting ${AGENT_LABEL} so it re-reads the preference ..."
  launchctl kickstart -k "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null \
    || { warn "kickstart failed; trying killall"; killall appstoreagent 2>/dev/null; }
  sleep 3
  info "appstoreagent pid now: $(pid_of appstoreagent)  (was ${ASA_PID_BEFORE})"
  say ""
  ok "Rollback complete. Re-check dasd CPU with:  top -l 3 -o cpu -n 20 -stats pid,command,cpu | grep dasd"
  exit 0
fi

#===============================================================================
# STEP 3 - decide the target date
#===============================================================================
step 3 "PLAN - compute the new value and show exactly what will change"

NEW_EPOCH=""
PROPOSED_RAW=""

if (( DURABLE )); then
  d_epoch="$(to_epoch "$DURABLE_DATE")"
  if [[ -z "$d_epoch" ]]; then
    bad "Internal error: could not parse DURABLE_DATE ('${DURABLE_DATE}')."
    die $E_STATE "Bad durable date constant."
  fi
  if [[ -n "$CUR_EPOCH" && $d_epoch -le $CUR_EPOCH ]]; then
    bad "Durable target (${DURABLE_DATE}) is not after the current value."
    die $E_STATE "Refusing to move the date backwards."
  fi
  NEW_EPOCH=$d_epoch
  say "  Chosen strategy: ${C_BLD}DURABLE${C_RST}"
  note "    Sets the date far into the future so the task never comes due again."
  note "    Trade-off: Apple Arcade payout/engagement telemetry stops advancing."
  note "    (Developer payout bookkeeping - cosmetic for a normal user.)"
else
  [[ -n "$CUR_EPOCH" ]] || die $E_STATE "No current value to advance."
  NEW_EPOCH=$((CUR_EPOCH + CYCLE_SECONDS))
  say "  Chosen strategy: ${C_BLD}ADVANCE ONE CYCLE${C_RST} (+${CYCLE_SECONDS}s = 7 days)"
  note "    Stops the current episode. The upstream bug is unfixed, so expect"
  note "    a recurrence at the next weekly boundary. Re-run then, or use"
  note "    --durable to stop it permanently."
fi
PROPOSED_RAW="$(from_epoch "$NEW_EPOCH")"
[[ -n "$PROPOSED_RAW" ]] || die $E_STATE "Could not format the new date."

NOW_EPOCH2=$(date +%s)
LEAD=$((NEW_EPOCH - NOW_EPOCH2))

say ""
say "  ${C_BLD}Proposed change${C_RST}"
say "  ------------------------------------------------------------------"
info "domain : ${PREF_DOMAIN}"
info "key    : ${PREF_KEY}"
info "type   : date   (must remain a real <date>, not a <string>)"
info "before : ${CUR_RAW}"
info "after  : ${C_BLD}${PROPOSED_RAW}${C_RST}"
say ""
info "before -> local : $(human_local "$CUR_EPOCH")"
info "after  -> local : $(human_local "$NEW_EPOCH")"
if [[ $LEAD -gt 0 ]]; then
  ok "New value is ${LEAD}s ($(( LEAD / 3600 ))h) in the FUTURE. The submitted"
  note "    window will no longer be past-dated, so DAS stops seeing the task"
  note "    as overdue and the loop ends."
else
  bad "New value is NOT in the future (${LEAD}s). This will not fix anything."
  die $E_ABORT "Refusing to apply a non-future date."
fi
say ""
say "  Also performed:"
info "1. Timestamped backup of the whole preference file."
info "2. Restart of the user agent ${AGENT_LABEL} so it re-reads the value."
info "3. Re-read of the preference afterwards, to detect the daemon"
info "   reverting it (which would mean the value is also cached elsewhere)."
info "4. CPU re-measurement of dasd to confirm the loop actually stopped."
say ""

if [[ "$MODE" == "dryrun" ]]; then
  say "  ${C_YEL}DRY RUN - nothing will be changed.${C_RST}"
  say ""
  say "  To apply for real, re-run without --dry-run."
  say ""
  exit 0
fi

#===============================================================================
# STEP 4 - confirmation
#===============================================================================
step 4 "CONFIRMATION"

if (( ASSUME_YES )); then
  warn "--yes supplied: applying without prompting."
else
  if [[ ! -t 0 ]]; then
    bad "stdin is not a terminal, so the confirmation prompt cannot be shown."
    note "    Re-run with --yes to apply unattended, or --dry-run to preview."
    die $E_ABORT "Not applying changes."
  fi
  say "  About to write the value shown in STEP 3 and restart ${AGENT_LABEL}."
  say "  This is reversible at any time with:  $0 --rollback"
  say ""
  read -r -p "  Proceed? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ok "Confirmed." ;;
    *) die $E_ABORT "Cancelled by user." ;;
  esac
fi
say ""

#===============================================================================
# STEP 5 - backup
#===============================================================================
step 5 "BACKUP - snapshot the preference file before touching anything"

TS="$(date +%Y%m%d-%H%M%S)"
if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
  bad "Could not create backup directory: ${BACKUP_DIR}"
  note "    Use --backup-dir to choose a writable location."
  die $E_PREFLIGHT "Cannot write backups; refusing to proceed without one."
fi
ok "Backup directory ready: ${BACKUP_DIR}"

BACKUP_FILE="${BACKUP_DIR}/${PREF_DOMAIN}.plist.${TS}.bak"
if cp "$HOME/Library/Preferences/${PREF_DOMAIN}.plist" "$BACKUP_FILE" 2>/dev/null; then
  ok "Plist backed up: ${BACKUP_FILE}"
  ls -l "$BACKUP_FILE" | sed 's/^/    /'
  if [[ -n "$CUR_RAW" ]]; then
    printf '%s\n' "$CUR_RAW" > "${BACKUP_DIR}/original-date.txt"
    ok "Original value saved to ${BACKUP_DIR}/original-date.txt"
    info "  content: ${CUR_RAW}"
  fi
else
  bad "Could not copy the preference file to ${BACKUP_FILE}"
  die $E_PREFLIGHT "No backup - aborting rather than risk an unrecoverable change."
fi
say ""

#===============================================================================
# STEP 6 - write the new value (with format fallback + type verification)
#===============================================================================
step 6 "APPLY - write the new ArcadePayoutResetDate"

# `defaults -date` argument parsing has varied across macOS releases, so we try
# the documented NSDate-description form first, verify that a real <date> was
# stored, and fall back to the ISO form. Any wrong-type write is reverted
# immediately, so we never leave the preference in a bad state.
attempt_write() {
  local value="$1" label="$2"
  say "  Attempt: ${label}"
  info "command: defaults write ${PREF_DOMAIN} ${PREF_KEY} -date \"${value}\""
  if ! defaults write "$PREF_DOMAIN" "$PREF_KEY" -date "$value" 2>/dev/null; then
    bad "  defaults write returned non-zero."
    return 1
  fi
  local got type
  got="$(read_pref)"
  type="$(pref_type)"
  info "  read back : ${got:-<empty>}"
  info "  plist type: ${type}"
  if [[ "$type" != "date" ]]; then
    bad "  Stored as '${type}', not 'date'. Reverting this attempt."
    return 1
  fi
  ok "  Stored as a real <date>."
  return 0
}

WRITTEN=0
if attempt_write "$PROPOSED_RAW" "NSDate description form"; then
  WRITTEN=1
else
  warn "Falling back to ISO-8601 form."
  ISO_VAL="$(TZ=UTC0 date -r "$NEW_EPOCH" "+%Y-%m-%dT%H:%M:%SZ")"
  if [[ -z "$ISO_VAL" ]]; then
    bad "Could not format the ISO fallback."
  else
    if attempt_write "$ISO_VAL" "ISO-8601 form"; then
      WRITTEN=1
    fi
  fi
fi

if (( ! WRITTEN )); then
  bad "Could not store ${PREF_KEY} as a date with either format."
  note "    Restoring the backup and re-registering the original value."
  cp "$BACKUP_FILE" "$HOME/Library/Preferences/${PREF_DOMAIN}.plist" 2>/dev/null
  [[ -n "$CUR_RAW" ]] && defaults write "$PREF_DOMAIN" "$PREF_KEY" -date "$CUR_RAW" 2>/dev/null
  note "    Value is now: $(read_pref)"
  die $E_WRITE "Write failed; original state restored."
fi

say ""
say "  Final stored value:"
info "defaults read : $(read_pref)"
info "plist xml     : $(plutil -convert xml1 -o - "$HOME/Library/Preferences/${PREF_DOMAIN}.plist" 2>/dev/null \
                            | grep -A1 "<key>${PREF_KEY}</key>" | grep '<date>' | sed 's/^[[:space:]]*//')"
say ""

#===============================================================================
# STEP 7 - restart the agent so it re-reads the preference
#===============================================================================
step 7 "RESTART - make ${AGENT_LABEL} re-read the preference"

info "PID before: ${ASA_PID_BEFORE:-<none>}"
say ""
say "  Trying launchctl kickstart (preferred - clean, launchd-managed restart)..."
if launchctl kickstart -k "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null; then
  ok "kickstart succeeded."
else
  warn "kickstart failed or is unsupported; falling back to killall."
  if killall appstoreagent 2>/dev/null; then
    ok "killall sent; launchd will respawn it."
  else
    bad "Both kickstart and killall failed."
  fi
fi

info "Waiting for it to come back ..."
sleep 3
ASA_PID_AFTER="$(pid_of appstoreagent)"
info "PID after : ${ASA_PID_AFTER:-<none>}"
info "all pids  : $(agent_pids)"
if [[ -z "$ASA_PID_AFTER" ]]; then
  warn "appstoreagent is not currently running. This is normal if it was"
  note "    demand-launched and is idle; the corrected value will be read the"
  note "    next time it starts."
elif [[ "$ASA_PID_AFTER" != "$ASA_PID_BEFORE" ]]; then
  ok "Restarted (PID changed ${ASA_PID_BEFORE:-none} -> ${ASA_PID_AFTER})."
else
  warn "PID is unchanged (${ASA_PID_AFTER}). The restart may not have taken."
  note "    Not fatal - the preference is still correct on disk."
fi
say ""

# Did the daemon revert our value?
REVERTED=""
if [[ -n "$ASA_PID_AFTER" ]]; then
  sleep 4
  NOW_RAW="$(read_pref)"
  NOW_EPOCH="$(to_epoch "$NOW_RAW" 2>/dev/null || true)"
  info "Preference re-read after restart: ${NOW_RAW}"
  if [[ -n "$NOW_EPOCH" ]] && [[ "$NOW_EPOCH" -lt "$NEW_EPOCH" ]]; then
    bad "The value appears to have been moved BACK (expected ${PROPOSED_RAW})."
    REVERTED=1
  elif [[ "$NOW_RAW" == "$CUR_RAW" ]]; then
    bad "The daemon reverted the preference to the original value."
    REVERTED=1
  else
    ok "Value held: the agent did not overwrite it."
  fi
fi
say ""

#===============================================================================
# STEP 8 - verify the loop actually stopped (measure CPU)
#===============================================================================
step 8 "VERIFY - did the loop actually stop?"

say "  Sampling dasd CPU. The loop stops within a second or two of the agent"
say "  re-reading the value; we wait a few seconds to be sure."
say ""
VERIFY_OK=0
for i in 1 2 3; do
  sleep 4
  d="$(proc_cpu dasd)"
  a="$(proc_cpu appstoreagent)"
  info "sample ${i}: dasd=$(fmt_cpu "$d")   appstoreagent=$(fmt_cpu "$a")"
  if [[ "$d" =~ ^[0-9.]+$ ]]; then
    if awk -v x="$d" 'BEGIN{exit !(x < 1.0)}'; then VERIFY_OK=1; fi
  elif [[ "$d" == "not-shown" ]]; then
    VERIFY_OK=1   # below the top-100 cutoff = effectively idle
  fi
done
say ""

#===============================================================================
# STEP 9 - summary
#===============================================================================
step 9 "RESULT SUMMARY"

info "CPU before (dasd)     : $(fmt_cpu "$DASD_CPU_BEFORE")"
info "CPU after  (dasd)     : $(fmt_cpu "$(proc_cpu dasd)")"
info "CPU before (agent)    : $(fmt_cpu "$ASA_CPU_BEFORE")"
info "CPU after  (agent)    : $(fmt_cpu "$(proc_cpu appstoreagent)")"
say ""

if (( VERIFY_OK )); then
  ok "dasd is now below 1% of a core - the loop has stopped."
elif [[ -n "$REVERTED" ]]; then
  bad "dasd is still busy AND the preference was reverted."
  note "    The value is cached somewhere other than this preference (likely"
  note "    inside appstored). Next steps, in order:"
  note "      1. sudo launchctl kickstart -k system/${DAEMON_LABEL}"
  note "      2. Re-run this script, then check the value again."
  note "      3. If it still reverts, the App Store local state needs the"
  note "         heavier reset (delete ${PREF_DOMAIN} prefs + caches)."
else
  warn "dasd is still above 1%. Give it another minute and re-measure:"
  note "      top -l 3 -o cpu -n 20 -stats pid,command,cpu | grep dasd"
  note "    If it stays high, the agent may not have re-read the value yet."
fi
say ""

say ""
say "  ${C_BLD}Also note:${C_RST} logd has quarantined dasd/appstoreagent, so their log"
say "  output is being DROPPED. The loop could be running while barely logging."
say "  Measure with CPU (as above), never by log volume, until you restart:"
note "      sudo launchctl kickstart -k system/com.apple.dasd"
note "    (Only do that AFTER the loop is fixed, or it re-quarantines.)"
say ""
say "  Bug reference: DAS activity ${TASK_NAME} (ArcadePayoutReset)."
say ""

say "  ${C_BLD}Artifacts:${C_RST}"
info "backup plist  : ${BACKUP_FILE}"
info "original value: ${BACKUP_DIR}/original-date.txt  (${CUR_RAW})"
say ""

if (( DURABLE )); then
  say "  Strategy was DURABLE - this task should not come due again."
else
  say "  Strategy was ADVANCE ONE CYCLE. ${C_YEL}Expect a recurrence at the next"
  say "  weekly boundary: $(human_local "$NEW_EPOCH")${C_RST}"
  note "    If that happens, re-run this script, or use --durable to stop it"
  note "    permanently. Please also report the bug to Apple - see below."
fi
say ""

say "  ${C_BLD}Rollback (any time):${C_RST}"
say "      $0 --rollback"
say ""
say "  ${C_BLD}Please report this to Apple${C_RST} (Feedback Assistant). It is a clean,"
say "  reproducible bug: ArcadePayoutReset fails to advance its next-run date on"
say "  the weekly boundary, busy-loops ~69,000x at ~150 iterations/sec, and"
say "  floods the unified log at ~2,000 lines/sec until logd quarantines dasd."
say ""

if (( VERIFY_OK )); then
  ok "Done."
  exit 0
else
  warn "Done, but verification was inconclusive. See STEP 8/9 above."
  exit $E_VERIFY
fi
