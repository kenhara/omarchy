# Shared by omarchy-dns, omarchy-parent-dns, and the NetworkManager dispatcher.
# Provider tables, detection, NetworkManager + resolved writers, and the child
# lock. Sourced; no shebang.

NM_DNS_CONF="${OMARCHY_NM_DNS_CONF:-/etc/NetworkManager/conf.d/20-omarchy-dns.conf}"
RESOLVED_CONF="${OMARCHY_RESOLVED_CONF:-/etc/systemd/resolved.conf}"
PARENT_CONF="${OMARCHY_PARENT_CONF:-/etc/omarchy/parent.conf}"
QUAD9_FALLBACK="9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net"

# Cloudflare 1.1.1.1 for Families, verified against Cloudflare's published
# anycast and DoT hostnames (developers.cloudflare.com/1.1.1.1/setup/).
dns_provider_from_arg() {
  case "${1:-}" in
  Cloudflare | cloudflare)
    echo "Cloudflare"
    ;;
  Google | google)
    echo "Google"
    ;;
  Families | families)
    echo "Families"
    ;;
  Security | security)
    echo "Security"
    ;;
  DHCP | dhcp)
    echo "DHCP"
    ;;
  Custom | custom)
    echo "Custom"
    ;;
  *)
    return 1
    ;;
  esac
}

dns_child_profile() {
  local profile_file="${OMARCHY_PROFILE_FILE:-/etc/omarchy/profile}"
  [[ -f $profile_file && $(<"$profile_file") == "child" ]]
}

# One word from parent.conf: families, security, or off. Missing key is off
# (the machine has not been locked). Unknown values fall back to families,
# the restrictive default, the way wifi= treats unknown as parent.
dns_parent_mode() {
  local value=""
  if [[ -f $PARENT_CONF ]]; then
    value=$(sed -n "s/^[[:space:]]*dns[[:space:]]*=[[:space:]]*//p" "$PARENT_CONF" | tail -1)
    value=${value%"${value##*[![:space:]]}"}
  fi
  case "$value" in
    "" | off) echo off ;;
    security) echo security ;;
    families | on) echo families ;;
    *) echo families ;;
  esac
}

# Empty when the kid (or anyone) may change DNS. Otherwise the omarchy-dns
# provider name the lock is holding: Families or Security.
dns_locked_provider() {
  dns_child_profile || { echo ""; return 0; }
  case "$(dns_parent_mode)" in
    families) echo "Families" ;;
    security) echo "Security" ;;
    *) echo "" ;;
  esac
}

dns_refuse_if_locked() {
  local wanted="$1"
  local locked
  locked=$(dns_locked_provider)
  [[ -n $locked ]] || return 0
  [[ $wanted == "$locked" ]] && return 0
  echo "Family DNS is locked to $locked. Use sudo omarchy-parent dns to change it." >&2
  return 1
}

networkmanager_global_dns() {
  [[ -f $NM_DNS_CONF ]] || return 0

  awk -F= '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[global-dns-domain-\*\][[:space:]]*$/ { in_default = 1; next }
    /^[[:space:]]*\[/ { in_default = 0 }
    in_default && /^[[:space:]]*servers[[:space:]]*=/ {
      value = $0
      sub(/^[^=]*=/, "", value)
      print value
      exit
    }
  ' "$NM_DNS_CONF"
}

resolved_dns() {
  awk -F= '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*DNS[[:space:]]*=/ {
      value=$0
      sub(/^[^=]*=/, "", value)
      print value
      exit
    }
  ' "$RESOLVED_CONF" 2>/dev/null || true
}

# Families and Security first: both hostnames contain cloudflare-dns.com, and
# 1.1.1.3 is not 1.1.1.1, but a substring match on cloudflare-dns.com would
# otherwise label Families as Cloudflare.
current_dns_provider() {
  local dns=""
  local compact=""

  dns=$(networkmanager_global_dns)
  if [[ -z $(printf '%s' "$dns" | tr -d '[:space:],') ]]; then
    dns=$(resolved_dns)
  fi

  compact=$(printf '%s' "$dns" | tr -d '[:space:],')

  if [[ -z $compact ]]; then
    echo "DHCP"
  elif [[ $dns == *"family.cloudflare-dns.com"* || $dns == *"1.1.1.3"* || $dns == *"2606:4700:4700::1113"* ]]; then
    echo "Families"
  elif [[ $dns == *"security.cloudflare-dns.com"* || $dns == *"1.1.1.2"* || $dns == *"2606:4700:4700::1112"* ]]; then
    echo "Security"
  elif [[ $dns == *"cloudflare-dns.com"* || $dns == *"1.1.1.1"* || $dns == *"2606:4700:4700::1111"* ]]; then
    echo "Cloudflare"
  elif [[ $dns == *"dns.google"* || $dns == *"8.8.8.8"* || $dns == *"2001:4860:4860::8888"* ]]; then
    echo "Google"
  else
    echo "Custom"
  fi
}

normalize_servers() {
  printf '%s\n' "$*" | tr ',\t\n' ' ' | xargs | tr ' ' ','
}

split_dns_servers() {
  local servers="$1"
  local server clean
  ipv4_dns=""
  ipv6_dns=""

  for server in ${servers//,/ }; do
    clean=${server#dns+tls://}
    clean=${clean#dns+udp://}
    clean=${clean%%#*}
    clean=${clean#[}
    clean=${clean%]}

    [[ -n $clean ]] || continue
    if [[ $clean == *:* ]]; then
      ipv6_dns+="${ipv6_dns:+ }$clean"
    else
      ipv4_dns+="${ipv4_dns:+ }$clean"
    fi
  done
}

write_networkmanager_dns() {
  local servers="$1"

  install -d -m 0755 "$(dirname "$NM_DNS_CONF")"
  # omarchy:heredoc-expands paths=none -- $servers is a normalized, single-line
  # DNS server list written as data, not a path or command; nothing user-writable
  # is resolved or executed from the root-owned drop-in.
  cat >"$NM_DNS_CONF" <<EOF
# Managed by omarchy-dns. Remove this file or run omarchy dns DHCP to use DHCP DNS again.
[global-dns]

[global-dns-domain-*]
servers=$servers
EOF
}

clear_networkmanager_dns() {
  rm -f "$NM_DNS_CONF"
}

networkmanager_dns_connection() {
  case "$1" in
    802-11-wireless|802-3-ethernet) return 0 ;;
    *) return 1 ;;
  esac
}

set_one_connection_dns() {
  local uuid="$1"
  local ipv4_dns="${2:-}"
  local ipv6_dns="${3:-}"

  nmcli connection modify "$uuid" \
    ipv4.ignore-auto-dns yes \
    ipv4.dns "$ipv4_dns" \
    ipv6.ignore-auto-dns yes \
    ipv6.dns "$ipv6_dns" \
    >/dev/null
}

nmcli_ready() {
  command -v nmcli >/dev/null && nmcli general status >/dev/null 2>&1
}

set_connection_dns() {
  local uuid type
  local ipv4_dns="${1:-}"
  local ipv6_dns="${2:-}"

  nmcli_ready || return 0

  while IFS=: read -r uuid type; do
    [[ -n $uuid ]] || continue
    networkmanager_dns_connection "$type" || continue
    set_one_connection_dns "$uuid" "$ipv4_dns" "$ipv6_dns"
  done < <(nmcli -t -f UUID,TYPE connection show)
}

clear_connection_dns() {
  local uuid type

  nmcli_ready || return 0

  while IFS=: read -r uuid type; do
    [[ -n $uuid ]] || continue
    networkmanager_dns_connection "$type" || continue

    nmcli connection modify "$uuid" \
      ipv4.ignore-auto-dns no \
      ipv4.dns "" \
      ipv6.ignore-auto-dns no \
      ipv6.dns "" \
      >/dev/null
  done < <(nmcli -t -f UUID,TYPE connection show)
}

reapply_active_dns_connections() {
  local device type state

  while IFS=: read -r device type state; do
    [[ -n $device && $state == connected ]] || continue
    case "$type" in
      wifi|ethernet)
        nmcli device reapply "$device" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(nmcli -t -f DEVICE,TYPE,STATE device status)
}

reload_dns_stack() {
  if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
    # Load the updated NetworkManager config first, then reapply the active
    # profiles. A single conf,dns-full reload here pushes the old active DNS
    # settings, making the shell toggle appear one selection behind.
    nmcli general reload conf >/dev/null 2>&1 || systemctl reload NetworkManager.service 2>/dev/null || true
    reapply_active_dns_connections
  fi

  systemctl reload systemd-resolved.service 2>/dev/null || systemctl restart systemd-resolved.service 2>/dev/null || true

  if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
    # A resolved reload/restart can leave per-link DNS stale or empty; ask
    # NetworkManager to publish DNS after resolved has reread its config.
    nmcli general reload dns-full >/dev/null 2>&1 || true
  fi
}

# Unfiltered Quad9 is only a fallback for adult Cloudflare/Google/Custom.
# Families, Security, and every child-profile write omit it so an unreachable
# Cloudflare cannot silently become unfiltered DNS.
dns_fallback() {
  if dns_child_profile; then
    echo ""
    return
  fi
  echo "$QUAD9_FALLBACK"
}

write_resolved_conf() {
  local dns="${1:-}"
  local fallback="${2:-}"
  local dot="${3:-}"
  local tmp

  tmp=$(mktemp)
  {
    echo "[Resolve]"
    [[ -n $dns ]] && echo "DNS=$dns"
    [[ -n $fallback ]] && echo "FallbackDNS=$fallback"
    [[ -n $dot ]] && echo "DNSOverTLS=$dot"
  } >"$tmp"
  install -m 0644 -T "$tmp" "$RESOLVED_CONF"
  rm -f "$tmp"
}

dns_apply_provider() {
  local provider="$1"
  local custom_servers="${2:-}"
  local fallback

  case "$provider" in
  Cloudflare)
    fallback=$(dns_fallback)
    write_networkmanager_dns "1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001"
    set_connection_dns "1.1.1.1 1.0.0.1" "2606:4700:4700::1111 2606:4700:4700::1001"
    write_resolved_conf \
      "1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com" \
      "$fallback" \
      "opportunistic"
    ;;

  Google)
    fallback=$(dns_fallback)
    write_networkmanager_dns "8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844"
    set_connection_dns "8.8.8.8 8.8.4.4" "2001:4860:4860::8888 2001:4860:4860::8844"
    write_resolved_conf \
      "8.8.8.8#dns.google 8.8.4.4#dns.google 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google" \
      "$fallback" \
      "opportunistic"
    ;;

  Families)
    write_networkmanager_dns "1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003"
    set_connection_dns "1.1.1.3 1.0.0.3" "2606:4700:4700::1113 2606:4700:4700::1003"
    write_resolved_conf \
      "1.1.1.3#family.cloudflare-dns.com 1.0.0.3#family.cloudflare-dns.com 2606:4700:4700::1113#family.cloudflare-dns.com 2606:4700:4700::1003#family.cloudflare-dns.com" \
      "" \
      "yes"
    ;;

  Security)
    write_networkmanager_dns "1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002"
    set_connection_dns "1.1.1.2 1.0.0.2" "2606:4700:4700::1112 2606:4700:4700::1002"
    write_resolved_conf \
      "1.1.1.2#security.cloudflare-dns.com 1.0.0.2#security.cloudflare-dns.com 2606:4700:4700::1112#security.cloudflare-dns.com 2606:4700:4700::1002#security.cloudflare-dns.com" \
      "" \
      "yes"
    ;;

  DHCP)
    clear_networkmanager_dns
    clear_connection_dns
    write_resolved_conf "" "" "no"
    ;;

  Custom)
    split_dns_servers "$custom_servers"
    write_networkmanager_dns "$custom_servers"
    set_connection_dns "$ipv4_dns" "$ipv6_dns"
    fallback=$(dns_fallback)
    write_resolved_conf "${custom_servers//,/ }" "$fallback" ""
    ;;

  *)
    return 1
    ;;
  esac
}

# Servers the lock wants on a single connection. Used by the dispatcher so a
# new school Wi-Fi profile cannot keep DHCP DNS.
dns_lock_servers() {
  case "$(dns_locked_provider)" in
    Families)
      echo "1.1.1.3 1.0.0.3"
      echo "2606:4700:4700::1113 2606:4700:4700::1003"
      ;;
    Security)
      echo "1.1.1.2 1.0.0.2"
      echo "2606:4700:4700::1112 2606:4700:4700::1002"
      ;;
    *)
      return 1
      ;;
  esac
}

dns_connection_already_locked() {
  local uuid="$1"
  local ipv4="$2"
  local ipv6="$3"
  local ignore4 ignore6 have4 have6

  ignore4=$(nmcli -g ipv4.ignore-auto-dns connection show "$uuid" 2>/dev/null || true)
  ignore6=$(nmcli -g ipv6.ignore-auto-dns connection show "$uuid" 2>/dev/null || true)
  have4=$(nmcli -g ipv4.dns connection show "$uuid" 2>/dev/null || true)
  have6=$(nmcli -g ipv6.dns connection show "$uuid" 2>/dev/null || true)

  [[ $ignore4 == "yes" && $ignore6 == "yes" && $have4 == "$ipv4" && $have6 == "$ipv6" ]]
}

dns_lock_one_connection() {
  local uuid="$1"
  local ipv4 ipv6 type device

  type=$(nmcli -g connection.type connection show "$uuid" 2>/dev/null || true)
  networkmanager_dns_connection "$type" || return 0

  mapfile -t servers < <(dns_lock_servers) || return 0
  ipv4=${servers[0]:-}
  ipv6=${servers[1]:-}
  [[ -n $ipv4 ]] || return 0
  dns_connection_already_locked "$uuid" "$ipv4" "$ipv6" && return 0
  set_one_connection_dns "$uuid" "$ipv4" "$ipv6"
  device=$(nmcli -g connection.interface-name connection show "$uuid" 2>/dev/null || true)
  [[ -n $device && $device != "--" ]] && nmcli device reapply "$device" >/dev/null 2>&1 || true
}
