#!/bin/sh
# Keep wpa_supplicant joined to a saved network for the whole Wi-Fi session.
# Without this it can sit idle in DISCONNECTED for good:
#  - wpa_supplicant 2.12 drops an ABORTED scan without scheduling another one
#    (events.c: "Scan was aborted - do not use the incomplete scan results to
#    trigger new operations" -> scan_work_done; even autoscan is never told).
#    brcmfmac aborts scans while the chip is being configured (e.g. the country
#    iovar that a regdomain change sends, on bring-up and on every new wiphy),
#    so the one connection scan after start / after a re-probe can be lost.
#  - On-device (je2e.1) it also stayed idle >150 s after a mid-session drop and
#    after an ASSOC-REJECT (status 16, weak/crowded AP). Nothing of ours stops
#    wpa's own retry (the conf has no bgscan/ap_scan/disabled; no script sends
#    DISCONNECT/DISABLE_NETWORK), so it is recovered here, cheaply.
#  - `wpa_cli reconnect` does nothing in that state: RECONNECT only acts when
#    the `disconnected` flag (set by an explicit DISCONNECT) is set. REASSOCIATE
#    always requests a connection (wpas_request_connection: new scan + select).
#
#   wifi_join.sh start           wifi_up.sh / wifi_dhcp.sh hotplug: start a
#                                detached watcher and return at once
#   wifi_join.sh worker <token>  (internal) join phase: poll every POLL s for
#                                JOIN_SECS, REASSOCIATE while idle. Then monitor
#                                phase: one check every MON s; REASSOCIATE when
#                                idle on two checks in a row; when COMPLETED,
#                                `wifi_dhcp.sh check` (one udhcpc on this
#                                wlan0, also after the join). Ends when
#                                wpa_supplicant goes away (Wi-Fi off).
#   wifi_join.sh decide <state>  the pure decision (host test): kick|wait|done|gone
#
# Kicks only when an ENABLED network exists, and only while holding the Wi-Fi
# power mutex (/run/wifi-power.lock, wifi_up.sh/wifi_down.sh): a busy lock means
# a power transition is running, so that round is skipped, never waited on.
# The newest `start` supersedes older watchers (token, as in wifi_dhcp.sh).
# Fails loud (kmsg) if no join happens in the join phase.
IFACE=wlan0
GEN=/run/wifi-join.gen
JOIN_SECS=${JOIN_SECS:-30}   # watch window
POLL=${POLL:-2}              # seconds between wpa_state polls
HOLD=${HOLD:-3}              # polls to leave a kick alone before kicking again
MON=${MON:-30}               # monitor phase: seconds between checks
MON_MAX=${MON_MAX:-0}        # monitor rounds before exiting (0 = until wpa goes; tests)
WIFI_LOCK=/run/wifi-power.lock

decide() {  # $1 = wpa_state (empty: no answer from wpa_supplicant)
	case "$1" in
	COMPLETED) echo done ;;
	# idle: nothing in flight and (after an aborted scan) nothing scheduled
	DISCONNECTED|INACTIVE) echo kick ;;
	"") echo gone ;;
	# SCANNING, AUTHENTICATING, ASSOCIATING, ASSOCIATED, 4WAY_HANDSHAKE,
	# GROUP_HANDSHAKE: in progress. INTERFACE_DISABLED: wlan0 is mid re-probe
	# (REASSOCIATE is refused then); wpa itself rescans once it is back.
	*) echo wait ;;
	esac
}

wcli() { wpa_cli -p /var/run/wpa_supplicant -i $IFACE "$@" 2>/dev/null; }
state() { wcli status | sed -n 's/^wpa_state=//p'; }
log() { echo "wifi_join: $*" >> /dev/kmsg 2>/dev/null; }
# any saved network without [DISABLED] (LIST_NETWORKS flags column, 2.12)
enabled() { wcli list_networks | sed 1d | grep -v '\[DISABLED\]' | grep -q .; }
LOCKED=0
trap '[ $LOCKED -eq 1 ] && rmdir "$WIFI_LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM
kick() {  # 0 = REASSOCIATE sent
	enabled || return 1
	mkdir "$WIFI_LOCK" 2>/dev/null || return 1   # power transition running: skip
	LOCKED=1
	wcli reassociate >/dev/null
	rmdir "$WIFI_LOCK" 2>/dev/null; LOCKED=0
	return 0
}

case "$1" in
decide) decide "$2" ;;
start)
	tok="$$.$(cut -d' ' -f1 /proc/uptime)"
	echo "$tok" > $GEN
	sh "$0" worker "$tok" </dev/null >/dev/null 2>&1 &
	;;
worker)
	i=0; kicks=0; hold=0; s=; seen=0
	while [ $((i * POLL)) -lt "$JOIN_SECS" ]; do
		[ "$(cat $GEN 2>/dev/null)" = "$2" ] || exit 0    # superseded
		s=$(state); [ -n "$s" ] && seen=1
		case $(decide "$s") in
		done) [ $kicks -gt 0 ] && log "joined after $kicks reassociate(s)"
			/usr/bin/wifi_dhcp.sh check   # joined: make sure ONE client runs on this wlan0
			break ;;
		# not up YET (hotplug fires before wifi_up.sh starts wpa): keep
		# polling; up and then gone = Wi-Fi turned off: stop.
		gone) [ $seen = 1 ] && { log "wpa_supplicant went away, stopping"; exit 1; } ;;
		kick) [ $hold -le 0 ] && kick && { kicks=$((kicks+1)); hold=$HOLD; } ;;
		esac
		hold=$((hold-1))
		sleep "$POLL"; i=$((i+1))
	done
	[ "$(cat $GEN 2>/dev/null)" = "$2" ] || exit 0
	[ $seen = 1 ] || { log "wpa_supplicant never answered in ${JOIN_SECS} s"; exit 1; }
	[ "$s" = COMPLETED ] || ! enabled || \
		log "not associated after ${JOIN_SECS} s (wpa_state=${s:-?}, $kicks reassociate(s)), monitoring"
	# monitor phase: one wpa_cli status every MON s, no busy polling
	idle=0; r=0
	while [ "$MON_MAX" = 0 ] || [ $r -lt "$MON_MAX" ]; do
		sleep "$MON"; r=$((r+1))
		[ "$(cat $GEN 2>/dev/null)" = "$2" ] || exit 0
		s=$(state)
		case $(decide "$s") in
		gone) exit 0 ;;                       # Wi-Fi off: normal end
		kick)
			idle=$((idle+1))
			# idle on two checks in a row (>= MON s): wpa is not retrying
			if [ $idle -ge 2 ] && kick; then
				log "idle in $s for >= ${MON} s, reassociate"; idle=0
			fi ;;
		done) idle=0
			# a client can die without us (DISCOVER timer fired in a re-probe
			# gap): start/restart one; a no-op when the right one runs
			/usr/bin/wifi_dhcp.sh check ;;
		*) idle=0 ;;
		esac
	done
	exit 0
	;;
*) echo "usage: $0 start|worker <tok>|decide <wpa_state>" >&2; exit 2 ;;
esac
exit 0
