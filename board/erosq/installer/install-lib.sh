#!/bin/sh
# Pure decision logic for the EROS Q installer. No device access, no writes.
# Sourced by init on the device and by tests/test_installer_lib.sh on the
# host, so it must stay POSIX sh and use only the busybox applets the
# installer initramfs carries (each one is a symlink there; a missing one
# fails silently).

# il_parse_mode <modefile> -> backup|install|stock|restore|upt|invalid|absent
# Return code: 0 for a recognized mode, 1 when the file exists but its content
# is unreadable or unknown ("invalid"), 2 when the file does not exist at all
# ("absent").
#
# Absent is its own case, not folded into "invalid": the developer modes are
# only ever entered by placing a mode file by hand, so a file that is not
# there at all means this card was never set up by a developer and this can
# only be the end-user (upt) path. init uses that to power off rather than
# reboot even when update.upt has also gone (a user deleting it to free
# space): a reboot there is an unbounded loop with nobody present to break
# it. Garbage content proves nothing about which path we are on, so that case
# stays "invalid" and init falls back to its weaker "update.upt is on the
# card" signal.
il_parse_mode() {
    [ -f "$1" ] || { echo absent; return 2; }
    _m=$(head -n1 "$1" | tr -d ' \t\r\n')
    case "$_m" in
        backup|install|stock|restore|upt) echo "$_m"; return 0 ;;
        *)                            echo invalid; return 1 ;;
    esac
}

# il_md5_ok <file> <expected-md5>
# ${var%% *} rather than `cut`: one less applet to depend on.
il_md5_ok() {
    [ -f "$1" ] || return 1
    _got=$(md5sum "$1") || return 1
    _got=${_got%% *}
    [ "$_got" = "$2" ]
}

# il_mtd_by_name <label> [sysfs-root] -> mtdN
# Skips the mtdNro mirror nodes, which carry the same name as their mtdN.
il_mtd_by_name() {
    _want=$1
    _root=${2:-/sys/class/mtd}
    for _d in "$_root"/mtd*; do
        [ -f "$_d/name" ] || continue
        case "$_d" in *ro) continue ;; esac
        [ "$(cat "$_d/name")" = "$_want" ] || continue
        echo "${_d##*/}"
        return 0
    done
    return 1
}

# il_find_ci <dir> <lowercase-name> -> prints the resolved path
# An ISO9660 filesystem mounted without Rock Ridge presents bare 8.3 names,
# and whether they arrive lowercased depends on the mount's `map=` default,
# a kernel config detail the .upt cannot pin down. Try the lowercase
# spelling, then the uppercase one. Only regular files count: a directory
# named nand.ubi is not a payload.
il_find_ci() {
    _d=$1; _n=$2
    [ -f "$_d/$_n" ] && { echo "$_d/$_n"; return 0; }
    _u=$(echo "$_n" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')
    [ -f "$_d/$_u" ] && { echo "$_d/$_u"; return 0; }
    return 1
}

# il_file_contains <file> <marker> -> 0 when the marker appears in the file.
# Content gate for payloads whose md5 proves only "this is the file we
# shipped", not "this is the right file". A pre-A/B U-Boot once matched its
# manifest perfectly and flashed cleanly, leaving a device whose B slot
# nothing could boot. A marker check catches a wrong-but-intact payload; a
# checksum never can.
il_file_contains() {
    [ -f "$1" ] || return 1
    grep -q "$2" "$1" 2>/dev/null
}

# il_should_abort <markerfile> -> 0 when a prior attempt already ran
il_should_abort() { [ -f "$1" ]; }

# il_result_line <status> <step> <detail>
il_result_line() { printf '%s|%s|%s\n' "$1" "$2" "$3"; }

# _il_line: strip a CR and trailing blanks from $_l. `read` has already
# dropped the leading blanks; a manifest edited on Windows ends in CRLF.
_il_line() {
    _l=${_l%"$(printf '\r')"}
    while :; do
        case "$_l" in
            *' '|*'	') _l=${_l%?} ;;
            *) return 0 ;;
        esac
    done
}

_il_lower() { echo "$1" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'; }

# il_upt_md5 <UPDATE.TXT> <member> -> the md5= of the section whose
# file_path= basename is <member>, compared case-insensitively. A .upt's
# UPDATE.TXT lists one section per partition:
#     kernel={
#             name=kernel
#             file_path=autoupdate/uimage.bin
#             md5=<32 hex>
#     }
# Fails (rc 1) when no section names the member, when two do, or when the
# md5 is not 32 hex digits: an ambiguous or broken manifest gates nothing.
il_upt_md5() {
    [ -f "$1" ] || return 1
    _want=$(_il_lower "$2")
    _fp=; _m=; _hit=; _n=0
    while read -r _l || [ -n "$_l" ]; do
        _il_line
        case "$_l" in
            *'={') _fp=; _m= ;;
            file_path=*) _fp=${_l#file_path=} ;;
            md5=*) _m=${_l#md5=} ;;
            '}')
                if [ -n "$_fp" ] && [ "$(_il_lower "${_fp##*/}")" = "$_want" ]; then
                    _hit=$_m; _n=$((_n + 1))
                fi
                _fp=; _m= ;;
        esac
    done < "$1"
    [ "$_n" -eq 1 ] || return 1
    _hit=$(_il_lower "$_hit")
    case "$_hit" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#_hit}" -eq 32 ] || return 1
    echo "$_hit"
}

# il_upt_product <VERSION.TXT> -> the name= value (the product the stock
# updater checks the .upt against). rc 1 when there is none.
il_upt_product() {
    [ -f "$1" ] || return 1
    while read -r _l || [ -n "$_l" ]; do
        _il_line
        case "$_l" in
            name=*) echo "${_l#name=}"; return 0 ;;
        esac
    done < "$1"
    return 1
}
