#!/bin/sh
# Keep udhcpc attached to the CURRENT wlan0.
#
# A brcmfmac re-probe (firmware rxctl timeout at boot, fw crash reset, rfkill
# cycle) destroys wlan0 and creates a new one with a new ifindex; the IPv4
# address dies with the old netdev. busybox udhcpc reads the ifindex once at
# start, so a client that was BOUND on the old wlan0 just sleeps until its
# renew timer (hours): "connected" with no IPv4. It has to be restarted.
# The udhcpc hook 10-ifindex records which ifindex the running client uses.
#
#   wifi_dhcp.sh ensure    wifi_up.sh: start udhcpc, or restart a stale one
#   wifi_dhcp.sh hotplug   mdev, on "add wlan0": wait for association, then
#                          restart a stale client -- or START one if none is
#                          running, but only while Wi-Fi is wanted
#                          (/run/wifi-want = 1) and wpa is COMPLETED: a client
#                          still in DISCOVER dies with its wlan0 (busybox
#                          udhcpc re-reads the iface on every retry timer and
#                          exits when it is gone), and nothing else would start
#                          one. Wanted+COMPLETED rules out a Wi-Fi going down.
#   wifi_dhcp.sh check     the same decision, synchronous (wifi_join.sh: after
#                          a join and on each monitor check). When wpa answers
#                          but is NOT COMPLETED, the lease belongs to a link
#                          that is gone: stop udhcpc and run its deconfig
#                          (address 0.0.0.0, resolv.conf entries dropped).
#                          erosq-ui calls this after forgetting the connected
#                          network. Busybox udhcpc does not deconfig on SIGTERM
#                          (only with -R), so the stale IPv4 used to stay.
#   wifi_dhcp.sh check-decide <wpa_state>   the pure check rule (host test):
#                          act|drop
#   wifi_dhcp.sh worker <token>   (internal: the detached hotplug worker)
#   wifi_dhcp.sh decide <running 0|1> <recorded ifindex> <current ifindex>
#                          the pure decision (host test): start|restart|keep
IFACE=wlan0
REC=/run/udhcpc.ifindex
LOCK=/run/wifi-dhcp.lock
WANT=/run/wifi-want
GEN=/run/wifi-dhcp.gen        # token of the newest hotplug worker
DECONFIG=${DECONFIG:-/usr/share/udhcpc/default.script}   # udhcpc's own script (host test: stub)

decide() {
	[ "$1" = 1 ] || { echo start; return; }
	# no record: the client is just starting (records at its first deconfig)
	[ -z "$2" ] || [ "$2" = "$3" ] && { echo keep; return; }
	echo restart
}

wanted() {  # Wi-Fi on (last UI intent) and associated: a client belongs here
	[ "$(cat $WANT 2>/dev/null)" = 1 ] || return 1
	wpa_cli -p /var/run/wpa_supplicant -i $IFACE status 2>/dev/null | grep -q '^wpa_state=COMPLETED'
}

lock() {  # mkdir mutex; breaks a lock whose holder died (killed, power cut)
	n=0
	while ! mkdir "$LOCK" 2>/dev/null; do
		h=$(cat "$LOCK/pid" 2>/dev/null)
		if [ -n "$h" ] && ! kill -0 "$h" 2>/dev/null; then
			rm -rf "$LOCK"; continue
		fi
		sleep 1; n=$((n+1))
		[ $n -ge 30 ] && { echo "wifi_dhcp: lock held by $h for 30 s, giving up" >> /dev/kmsg 2>/dev/null; return 1; }
	done
	echo $$ > "$LOCK/pid"
	trap 'rm -rf "$LOCK"' EXIT
	trap 'exit 1' INT TERM
}

stop_clients() {  # SIGTERM every udhcpc and WAIT until it is gone: a client
	# busy in its hook script handles the signal only after the hook returns,
	# so starting the new one right away left two clients side by side for
	# seconds (je2d TEST-PLAN 6.4). Bounded: SIGKILL after ~5 s.
	killall udhcpc 2>/dev/null
	n=0
	while pidof udhcpc >/dev/null 2>&1; do
		if [ $n -ge 50 ]; then
			echo "wifi_dhcp: udhcpc ignored SIGTERM for 5 s, killing it" >> /dev/kmsg 2>/dev/null
			killall -9 udhcpc 2>/dev/null; break
		fi
		sleep 0.1; n=$((n+1))
	done
}

check_decide() {  # $1 = wpa_state ('' = wpa not answering)
	# COMPLETED: keep/start one client (act). No answer: unchanged (act; a
	# start still needs wanted + COMPLETED). Any other state: not associated
	# right now -- only erosq-ui's forget calls `check` then (wifi_join.sh
	# calls it on COMPLETED only), so the old lease is dropped.
	case "$1" in
	COMPLETED|"") echo act ;;
	*) echo drop ;;
	esac
}

drop() {  # no association: stop the client, deconfig the address it set
	[ -e /sys/class/net/$IFACE ] || return 0
	lock || return 1
	if pidof udhcpc >/dev/null 2>&1; then
		echo "wifi_dhcp: not associated, dropping the old lease" >> /dev/kmsg 2>/dev/null
		stop_clients
	fi
	interface=$IFACE "$DECONFIG" deconfig >/dev/null 2>&1   # idempotent
	rm -rf "$LOCK"; trap - EXIT
	return 0
}

act() {  # $1 = ensure|hotplug
	[ -e /sys/class/net/$IFACE ] || return 0
	lock || return 1
	# Re-check after acting: if wlan0 was re-created meanwhile, decide again,
	# so the state we leave behind always matches the CURRENT wlan0.
	# started: a client we launched may not be visible to pidof yet; never
	# launch a second one next to it.
	tries=0; started=0
	while [ $tries -lt 3 ]; do
		cur=$(cat /sys/class/net/$IFACE/ifindex 2>/dev/null)
		[ -n "$cur" ] || break
		running=$started; pidof udhcpc >/dev/null 2>&1 && running=1
		d=$(decide $running "$(cat $REC 2>/dev/null)" "$cur")
		[ "$1" = hotplug ] && [ "$d" = start ] && ! wanted && d=keep
		case $d in
		restart)
			echo "wifi_dhcp: udhcpc was on a gone $IFACE, restarting it" >> /dev/kmsg 2>/dev/null
			stop_clients
			# record now: the new client is for THIS wlan0 (its deconfig hook
			# rewrites the same value moments later)
			echo "$cur" > $REC
			udhcpc -i $IFACE >/dev/null 2>&1 &
			started=1 ;;
		start)
			echo "$cur" > $REC
			udhcpc -i $IFACE >/dev/null 2>&1 &
			started=1 ;;
		esac
		[ "$(cat /sys/class/net/$IFACE/ifindex 2>/dev/null)" = "$cur" ] && break
		tries=$((tries+1))
	done
	# Hold the lock until a client we launched is visible to pidof (it is
	# still a forked sh for a moment): a second caller right behind us must
	# see it, or it would start a duplicate.
	n=0
	while [ $started = 1 ] && ! pidof udhcpc >/dev/null 2>&1 && [ $n -lt 20 ]; do
		sleep 0.05; n=$((n+1))
	done
	rm -rf "$LOCK"; trap - EXIT
	return 0
}

case "$1" in
decide)  decide "$2" "$3" "$4" ;;
ensure)  act ensure ;;
check)
	st=$(wpa_cli -p /var/run/wpa_supplicant -i $IFACE status 2>/dev/null | sed -n 's/^wpa_state=//p')
	case $(check_decide "$st") in
	drop) drop ;;
	*) act hotplug ;;
	esac ;;
check-decide) check_decide "$2" ;;
hotplug)
	# mdev runs us synchronously: hand off to a detached worker and return.
	# The newest add-event supersedes older workers (re-probes can come
	# seconds apart): only the worker holding the current token acts.
	# A new wlan0 under a running wpa_supplicant (kernel re-probe): wpa re-inits
	# on it and scans once; if that scan is aborted it idles in DISCONNECTED
	# for good. wifi_join.sh kicks it (detached; exits if wpa is not running).
	/usr/bin/wifi_join.sh start 2>/dev/null
	tok="$$.$(cut -d' ' -f1 /proc/uptime)"
	echo "$tok" > $GEN
	sh "$0" worker "$tok" </dev/null >/dev/null 2>&1 &
	;;
worker)
	i=0
	while [ $i -lt 20 ]; do
		[ "$(cat $GEN 2>/dev/null)" = "$2" ] || exit 0          # superseded
		wpa_cli -p /var/run/wpa_supplicant -i $IFACE status 2>/dev/null | \
			grep -q '^wpa_state=COMPLETED' && break
		sleep 1; i=$((i+1))
	done
	[ "$(cat $GEN 2>/dev/null)" = "$2" ] || exit 0
	act hotplug
	;;
*) echo "usage: $0 ensure|hotplug|check|worker <tok>|decide <running> <rec> <cur>|check-decide <state>" >&2; exit 2 ;;
esac
exit 0
