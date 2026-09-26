# Shared by omarchy-dns and omarchy-parent-dns: provider names, the current
# resolver, and whether a child install has family DNS locked. Sourced; no
# shebang. Writers stay in omarchy-dns so the privileged path keeps its
# trusted-PATH pin and sudoers match.

NM_DNS_CONF="${OMARCHY_NM_DNS_CONF:-/etc/NetworkManager/conf.d/20-omarchy-dns.conf}"
RESOLVED_CONF="${OMARCHY_RESOLVED_CONF:-/etc/systemd/resolved.conf}"

if ! declare -F conf_get >/dev/null; then
  source "${OMARCHY_PATH:-/usr/share/omarchy}/install/helpers/parent.sh"
fi

QUAD9_FALLBACK="9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net 2620:fe::9#dns.quad9.net"

dns_provider_from_arg() {
  case "${1:-}" in
  Cloudflare | cloudflare)
    echo "Cloudflare"
    ;;
  Families | families)
    echo "Families"
    ;;
  Security | security)
    echo "Security"
    ;;
  Google | google)
    echo "Google"
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

dns_networkmanager_global() {
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

dns_resolved() {
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

# Compare whole tokens so 1.1.1.30 or 11.1.1.3 do not look like 1.1.1.3.
# Split on spaces and commas, strip dns+tls:// / dns+udp:// and the #name
# suffix, then match the leftover address or the DoT name.
dns_detect_provider() {
  local dns=""
  local compact=""
  local token name
  local has_families=0 has_security=0 has_cloudflare=0 has_google=0

  dns=$(dns_networkmanager_global)
  if [[ -z $(printf '%s' "$dns" | tr -d '[:space:],') ]]; then
    dns=$(dns_resolved)
  fi

  compact=$(printf '%s' "$dns" | tr -d '[:space:],')

  if [[ -z $compact ]]; then
    echo "DHCP"
    return
  fi

  local IFS=$' \t,'
  for token in $dns; do
    [[ -n $token ]] || continue
    token=${token#dns+tls://}
    token=${token#dns+udp://}
    name=""
    if [[ $token == *#* ]]; then
      name=${token#*#}
      token=${token%%#*}
    fi
    token=${token#[}
    token=${token%]}

    case "$token" in
      1.1.1.3|1.0.0.3|2606:4700:4700::1113|2606:4700:4700::1003) has_families=1 ;;
      1.1.1.2|1.0.0.2|2606:4700:4700::1112|2606:4700:4700::1002) has_security=1 ;;
      1.1.1.1|1.0.0.1|2606:4700:4700::1111|2606:4700:4700::1001) has_cloudflare=1 ;;
      8.8.8.8|8.8.4.4|2001:4860:4860::8888|2001:4860:4860::8844) has_google=1 ;;
      family.cloudflare-dns.com) has_families=1 ;;
      security.cloudflare-dns.com) has_security=1 ;;
      cloudflare-dns.com) has_cloudflare=1 ;;
      dns.google) has_google=1 ;;
    esac
    case "$name" in
      family.cloudflare-dns.com) has_families=1 ;;
      security.cloudflare-dns.com) has_security=1 ;;
      cloudflare-dns.com) has_cloudflare=1 ;;
      dns.google) has_google=1 ;;
    esac
  done

  if (( has_families )); then
    echo "Families"
  elif (( has_security )); then
    echo "Security"
  elif (( has_cloudflare )); then
    echo "Cloudflare"
  elif (( has_google )); then
    echo "Google"
  else
    echo "Custom"
  fi
}

# Unset dns= on a child install is the default lock (on). Adults have no lock.
dns_mode() {
  local value
  value=$(conf_get dns "")
  case "$value" in
    on|security|off)
      printf '%s\n' "$value"
      ;;
    "")
      if dns_is_child; then
        echo on
      else
        echo off
      fi
      ;;
    *)
      echo on
      ;;
  esac
}

dns_is_child() {
  omarchy-profile-child
}

dns_locked() {
  dns_is_child || return 1
  [[ $(dns_mode) != "off" ]]
}

dns_omit_fallback() {
  dns_is_child && return 0
  case "${1:-}" in
    Families|Security) return 0 ;;
    *) return 1 ;;
  esac
}

dns_provider_nm_servers() {
  case "$1" in
    Cloudflare) echo "1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001" ;;
    Families) echo "1.1.1.3,1.0.0.3,2606:4700:4700::1113,2606:4700:4700::1003" ;;
    Security) echo "1.1.1.2,1.0.0.2,2606:4700:4700::1112,2606:4700:4700::1002" ;;
    Google) echo "8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844" ;;
    *) return 1 ;;
  esac
}

dns_provider_ipv4() {
  case "$1" in
    Cloudflare) echo "1.1.1.1 1.0.0.1" ;;
    Families) echo "1.1.1.3 1.0.0.3" ;;
    Security) echo "1.1.1.2 1.0.0.2" ;;
    Google) echo "8.8.8.8 8.8.4.4" ;;
    *) return 1 ;;
  esac
}

dns_provider_ipv6() {
  case "$1" in
    Cloudflare) echo "2606:4700:4700::1111 2606:4700:4700::1001" ;;
    Families) echo "2606:4700:4700::1113 2606:4700:4700::1003" ;;
    Security) echo "2606:4700:4700::1112 2606:4700:4700::1002" ;;
    Google) echo "2001:4860:4860::8888 2001:4860:4860::8844" ;;
    *) return 1 ;;
  esac
}

dns_provider_resolved() {
  case "$1" in
    Cloudflare) echo "1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com" ;;
    Families) echo "1.1.1.3#family.cloudflare-dns.com 1.0.0.3#family.cloudflare-dns.com 2606:4700:4700::1113#family.cloudflare-dns.com 2606:4700:4700::1003#family.cloudflare-dns.com" ;;
    Security) echo "1.1.1.2#security.cloudflare-dns.com 1.0.0.2#security.cloudflare-dns.com 2606:4700:4700::1112#security.cloudflare-dns.com 2606:4700:4700::1002#security.cloudflare-dns.com" ;;
    Google) echo "8.8.8.8#dns.google 8.8.4.4#dns.google 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google" ;;
    *) return 1 ;;
  esac
}

dns_provider_dot() {
  case "$1" in
    Families|Security) echo yes ;;
    Cloudflare|Google) echo opportunistic ;;
    DHCP) echo no ;;
    *) echo "" ;;
  esac
}

dns_lock_message() {
  echo "Family DNS is locked. A parent can change it with: sudo omarchy-parent dns on|off|security" >&2
}

dns_normalize_list() {
  printf '%s\n' "$*" | tr ',\t\n' ' ' | xargs
}

dns_locked_provider() {
  case "$(dns_mode)" in
    on) echo Families ;;
    security) echo Security ;;
    *) return 1 ;;
  esac
}
