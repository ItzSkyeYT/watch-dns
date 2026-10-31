#!/usr/bin/env bash
# watch-dns: your own DNS server for a Wear OS watch, even while it is online
# through the phone over Bluetooth.
#
#   bash watch-dns.sh                    menu
#   bash watch-dns.sh on [--dns IP]      turn the redirect on (default: AdGuard DNS)
#   bash watch-dns.sh off                turn it off
#   bash watch-dns.sh status             show what it is doing (only reads)
#   options: --serial SERIAL (or ANDROID_SERIAL), --app PACKAGE
#
# Needs adb on this computer and root (su) on the phone. See README.md.

set -u

GOOGLE4="8.8.8.8,8.8.4.4"
GOOGLE6="2001:4860:4860::8888,2001:4860:4860::8844"
COMPANIONS="com.google.android.apps.wear.companion com.google.android.wearable.app"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  B=$'\e[1m' D=$'\e[2m' R=$'\e[31m' G=$'\e[32m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
else
  B='' D='' R='' G='' Y='' C='' N=''
fi
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
info() { printf '  %s·%s %s\n' "$D" "$N" "$*"; }
die()  { bad "$*"; exit 1; }

usage() { sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//'; }

SERIAL="${ANDROID_SERIAL:-}"
PKG="${PKG:-}"
DNS="${DNS:-}"
ACTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    on|off|status) ACTION=$1 ;;
    --dns) DNS="${2:-}"; shift ;;
    --serial|-s) SERIAL="${2:-}"; shift ;;
    --app) PKG="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) if [ -n "$ACTION" ] && [ -z "$SERIAL" ]; then SERIAL=$1; else usage; exit 2; fi ;;
  esac
  shift
done

# ---------------------------------------------------------------- device side

read -r -d '' OFF_SH <<'EOF'
for t in "iptables -t nat" "iptables" "ip6tables"; do
  $t -S OUTPUT 2>/dev/null | grep -e "-j wdns$" | sed "s/^-A /-D /" | while read -r r; do $t $r; done
  $t -F wdns 2>/dev/null; $t -X wdns 2>/dev/null
done
EOF

read -r -d '' CHECK_SH <<'EOF'
for m in owner conntrack multiport; do iptables -m $m -h >/dev/null 2>&1 || echo "missing=$m match"; done
iptables -j DNAT -h >/dev/null 2>&1 || echo "missing=DNAT target"
iptables -t nat -S OUTPUT >/dev/null 2>&1 || echo "missing=nat table"
EOF

read -r -d '' ON_SH <<'EOF'
set -e
iptables -t nat -N wdns
iptables -t nat -A wdns -p udp --dport 53 -j DNAT --to-destination @DNS@:53
iptables -t nat -A wdns -p tcp --dport 53 -j DNAT --to-destination @DNS@:53
iptables -N wdns
iptables -A wdns -p udp --dport 53 -m conntrack ! --ctstate DNAT -j REJECT
iptables -A wdns -p tcp --dport 53 -m conntrack ! --ctstate DNAT -j REJECT --reject-with tcp-reset
iptables -A wdns -d @G4@ -p udp -m multiport --dports 443,853 -j REJECT
iptables -A wdns -d @G4@ -p tcp -m multiport --dports 443,853 -j REJECT --reject-with tcp-reset
ip6tables -N wdns
ip6tables -A wdns -p udp --dport 53 -j REJECT
ip6tables -A wdns -p tcp --dport 53 -j REJECT --reject-with tcp-reset
ip6tables -A wdns -d @G6@ -p udp -m multiport --dports 443,853 -j REJECT
ip6tables -A wdns -d @G6@ -p tcp -m multiport --dports 443,853 -j REJECT --reject-with tcp-reset
for u in @UIDS@; do
  iptables -t nat -I OUTPUT 1 -m owner --uid-owner $u -j wdns
  iptables -I OUTPUT 1 -m owner --uid-owner $u -j wdns
  ip6tables -I OUTPUT 1 -m owner --uid-owner $u -j wdns
done
echo applied
EOF

read -r -d '' STATUS_SH <<'EOF'
if iptables -t nat -S OUTPUT 2>/dev/null | grep -q -e "-j wdns$"; then echo state=on; else echo state=off; fi
iptables -t nat -S wdns 2>/dev/null | sed -n 's/.*--to-destination \([0-9.]*\):53.*/dns=\1/p' | head -n 1
echo "uids=$(iptables -t nat -S OUTPUT 2>/dev/null | sed -n 's/.*--uid-owner \([0-9]*\) -j wdns$/\1/p' | sort -n | tr '\n' ' ')"
iptables -t nat -L wdns -v -n -x 2>/dev/null | awk 'NR>2 {s+=$1} END {print "sent=" s+0}'
iptables -L wdns -v -n -x 2>/dev/null | awk 'NR>2 && /443,853/ {g+=$1} END {print "refused=" g+0}'
EOF

# ---------------------------------------------------------------- helpers

adbs()    { if [ -n "$SERIAL" ]; then adb -s "$SERIAL" "$@" </dev/null; else adb "$@" </dev/null; fi; }
root_sh() {
  if [ -n "$SERIAL" ]; then printf '%s\n' "$1" | adb -s "$SERIAL" shell su -c sh 2>/dev/null | tr -d '\r'
  else printf '%s\n' "$1" | adb shell su -c sh 2>/dev/null | tr -d '\r'; fi
}
prop()    { adb -s "$1" shell getprop "$2" </dev/null 2>/dev/null | tr -d '\r'; }
devices() { adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}'; }
is_watch() { case "$(prop "$1" ro.build.characteristics)" in *watch*) return 0 ;; esac; return 1; }

choose() { # title, options...  ->  REPLY = 1..n
  local title=$1 i=1 o; shift
  printf '\n%s%s%s\n' "$B" "$title" "$N"
  for o in "$@"; do printf '  %s%d%s  %s\n' "$C" "$i" "$N" "$o"; i=$((i + 1)); done
  while :; do
    printf '  %s›%s ' "$C" "$N"
    read -r REPLY || { echo; exit 0; }
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le $# ]; then return; fi
    printf '  %sType a number from 1 to %d.%s\n' "$D" $# "$N"
  done
}

dns_name() {
  case "$1" in
    94.140.14.14) echo "AdGuard DNS" ;;
    94.140.14.15) echo "AdGuard DNS Family" ;;
    1.1.1.2) echo "Cloudflare, malware blocking" ;;
    9.9.9.9) echo "Quad9" ;;
    *) echo "your server" ;;
  esac
}

app_name() {
  case "$1" in
    com.google.android.apps.wear.companion) echo "Pixel Watch app" ;;
    com.google.android.wearable.app) echo "Wear OS app" ;;
    *) echo "$1" ;;
  esac
}

valid_ip() {
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}

# ---------------------------------------------------------------- steps

pick_phone() {
  command -v adb >/dev/null || die "adb is not installed (Android platform-tools)."
  [ -n "$SERIAL" ] && return
  local s sn seen=" " phones=() labels=()
  for s in $(devices); do
    is_watch "$s" && continue
    sn=$(prop "$s" ro.serialno)
    case "$seen" in *" $sn "*) continue ;; esac
    seen="$seen$sn "
    phones+=("$s"); labels+=("$(prop "$s" ro.product.model)  ${D}$s${N}")
  done
  case ${#phones[@]} in
    0) die "No phone on adb. Plug it in or connect wireless debugging, and allow this computer." ;;
    1) SERIAL=${phones[0]} ;;
    *) choose "Which phone?" "${labels[@]}"; SERIAL=${phones[$((REPLY - 1))]} ;;
  esac
}

check_phone() {
  printf '\n'
  adbs get-state >/dev/null 2>&1 || die "Can't reach $SERIAL."
  ok "Phone: $(prop "$SERIAL" ro.product.model), Android $(prop "$SERIAL" ro.build.version.release)  ${D}$SERIAL${N}"
  [ "$(adbs shell su -c 'id -u' 2>/dev/null | tr -d '\r')" = 0 ] ||
    die "No root for adb. Your root app (Magisk, KernelSU, APatch) has to allow Shell."
  ok "Root"
  # every watch app on the phone is covered; each relays only while its watch is connected
  local p u w pairs
  pairs=$(adbs shell dumpsys companiondevice 2>/dev/null | tr -d '\r')
  APP_UIDS=''
  for p in ${PKG:-$COMPANIONS}; do
    u=$(adbs shell "pm list packages --user 0 -U $p" 2>/dev/null | sed -nE "s/.*$p uid:([0-9]+).*/\1/p" | tr -d '\r')
    [ -n "$u" ] || continue
    APP_UIDS="$APP_UIDS$u "
    w=$(printf '%s\n' "$pairs" | sed -nE "s/.*mPackageName='$p'.*mDisplayName='([^']*)'.*/\1/p" | tail -n 1)
    ok "Watch app: $(app_name "$p")${w:+  ${D}paired with $w${N}}"
  done
  [ -n "$APP_UIDS" ] || die "No watch app found (Pixel Watch app or Wear OS app). Is a watch paired with this phone?"
  APP_UIDS=$(printf '%s\n' $APP_UIDS | sort -n | tr '\n' ' ')
}

show_status() {
  local st=off sd='' su='' sent=0 refused=0 k v
  while IFS='=' read -r k v; do
    case "$k" in state) st=$v ;; dns) sd=$v ;; uids) su=$v ;; sent) sent=$v ;; refused) refused=$v ;; esac
  done <<<"$(root_sh "$STATUS_SH")"
  printf '\n'
  if [ "$st" = on ]; then
    ok "${B}On${N}: the watch's lookups go to $sd ($(dns_name "$sd"))"
    info "$sent sent there, $refused encrypted lookups to Google refused"
    [ "$sent" = 0 ] && info "Zero is normal while the watch is on Wi-Fi: this only works on Bluetooth."
    [ "$su" != "$APP_UIDS" ] && warn "The watch apps changed since it was turned on. Turn it on again to cover them."
  else
    info "${B}Off${N}: over Bluetooth, the watch's lookups go to Google."
  fi
  info "Rules last until the phone restarts."
}

pick_dns() {
  choose "Which DNS server?" \
    "AdGuard DNS          ${D}blocks ads and trackers${N}" \
    "AdGuard DNS Family   ${D}also adult sites, safe search on${N}" \
    "Cloudflare 1.1.1.2   ${D}blocks malware${N}" \
    "Quad9                ${D}blocks malware${N}" \
    "My own server        ${D}Pi-hole, AdGuard Home, any IPv4 address${N}"
  case "$REPLY" in
    1) DNS=94.140.14.14 ;;
    2) DNS=94.140.14.15 ;;
    3) DNS=1.1.1.2 ;;
    4) DNS=9.9.9.9 ;;
    5) while :; do
         printf '  IPv4 address %s›%s ' "$C" "$N"; read -r DNS || exit 0
         valid_ip "$DNS" && break
         printf '  %sThat is not an IPv4 address.%s\n' "$D" "$N"
       done
       case "$DNS" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*)
         warn "A home address only answers while the phone is on that network, or on a VPN to it (Tailscale, WireGuard)." ;;
       esac ;;
  esac
}

turn_on() {
  [ -n "$DNS" ] || DNS=94.140.14.14
  valid_ip "$DNS" || die "--dns needs an IPv4 address."
  local missing; missing=$(root_sh "$CHECK_SH" | sed -n 's/^missing=//p')
  [ -z "$missing" ] || die "This phone's kernel lacks: $(echo $missing | tr '\n' ' ')"
  local sh=${ON_SH//@DNS@/$DNS}; sh=${sh//@UIDS@/$APP_UIDS}; sh=${sh//@G4@/$GOOGLE4}; sh=${sh//@G6@/$GOOGLE6}
  if [ "$(root_sh "$OFF_SH"$'\n'"$sh" | tail -n 1)" != applied ]; then
    root_sh "$OFF_SH" >/dev/null
    die "The phone refused the rules, so they were taken out again. Nothing changed."
  fi
  printf '\n'; ok "Turned on: lookups go to $DNS ($(dns_name "$DNS"))"
}

turn_off() { root_sh "$OFF_SH" >/dev/null; printf '\n'; ok "Turned off"; }

check_watch() {
  local w seen_watch=0 mode spec
  for w in $(devices); do
    is_watch "$w" || continue
    seen_watch=1
    mode=$(adb -s "$w" shell settings get global private_dns_mode </dev/null 2>/dev/null | tr -d '\r')
    spec=$(adb -s "$w" shell settings get global private_dns_specifier </dev/null 2>/dev/null | tr -d '\r')
    printf '\n'; ok "Watch: $(prop "$w" ro.product.model)  ${D}$w${N}"
    if [ "$mode" = hostname ]; then
      warn "Its Private DNS is forced to $spec. Over Bluetooth that leaves it with no internet."
      printf '  Switch it to Automatic? [y/N] '; read -r a || a=n
      if [[ "$a" =~ ^[yY] ]]; then
        adb -s "$w" shell settings put global private_dns_mode opportunistic </dev/null && ok "Switched to Automatic"
      fi
    else
      case "$mode" in off) mode=Off ;; *) mode=Automatic ;; esac
      ok "Private DNS: $mode. Good, that works with the redirect."
    fi
  done
  if [ "$seen_watch" = 0 ]; then
    printf '\n'; info "No watch on adb, so it can't be checked from here."
    info "On the watch: Settings, Developer options, Wireless debugging. Then adb connect it."
    info "Or check by hand: its Private DNS must not be set to a hostname."
  fi
}

# ---------------------------------------------------------------- main

case "$ACTION" in
  on)     pick_phone; check_phone; turn_on; show_status ;;
  off)    pick_phone; check_phone; turn_off; show_status ;;
  status) pick_phone; check_phone; show_status ;;
  "")
    printf '\n  %swatch-dns%s  %syour DNS for a Wear OS watch, even over Bluetooth%s\n' "$B" "$N" "$D" "$N"
    pick_phone; check_phone; show_status
    while :; do
      choose "What now?" "Turn on, or change the server" "Turn off" "Show status" "Check the watch's own setting" "Quit"
      case "$REPLY" in
        1) pick_dns; turn_on; show_status ;;
        2) turn_off; show_status ;;
        3) show_status ;;
        4) check_watch ;;
        5) printf '\n'; exit 0 ;;
      esac
    done ;;
esac
