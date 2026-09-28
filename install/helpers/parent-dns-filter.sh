# Family DNS egress filter for a locked child install. Sourced; no shebang.
# Adds a dedicated nftables table so the kid uid cannot talk to an outside
# resolver on 53/853 or to well-known public DoH addresses on 443, while
# systemd-resolved (a system user) and root keep working. UFW stays the
# inbound firewall; this table only drops matching outbound packets.

PARENT_DNS_NFT_TABLE="${OMARCHY_PARENT_DNS_NFT_TABLE:-omarchy-parent-dns}"
PARENT_DNS_NFT_FILE="${OMARCHY_PARENT_DNS_NFT_FILE:-/etc/omarchy/parent-dns-filter.nft}"
PARENT_DNS_FILTER_UNIT="${OMARCHY_PARENT_DNS_FILTER_UNIT:-/etc/systemd/system/omarchy-parent-dns-filter.service}"

# The install chroot sees the live system's /run, so the directory alone
# would say yes there; loading nft there would mutate the installer's
# kernel firewall. Same check omarchy-parent uses for systemctl --now.
dns_filter_live() {
  [[ -d /run/systemd/system ]] && ! systemd-detect-virt --quiet --chroot 2>/dev/null
}

# Unfiltered public DoH anycast. Family (1.1.1.3 / ::1113 / 1.0.0.3 / ::1003)
# is never listed. Security (1.1.1.2 / ::1112) is listed only in Families
# mode so malware-only is not an adult-filter bypass.
dns_filter_doh_v4() {
  local mode="${1:-families}"

  cat <<'EOF'
8.8.8.8
8.8.4.4
1.1.1.1
1.0.0.1
9.9.9.9
9.9.9.10
9.9.9.11
149.112.112.112
149.112.112.10
149.112.112.11
208.67.222.222
208.67.220.220
208.67.222.123
208.67.220.123
94.140.14.14
94.140.15.15
94.140.14.15
94.140.15.16
185.228.168.9
185.228.169.9
185.228.168.10
185.228.169.11
76.76.2.0
76.76.10.0
194.242.2.2
EOF

  if [[ $mode == families || $mode == on ]]; then
    printf '%s\n' 1.1.1.2 1.0.0.2
  fi
}

dns_filter_doh_v6() {
  local mode="${1:-families}"

  cat <<'EOF'
2001:4860:4860::8888
2001:4860:4860::8844
2606:4700:4700::1111
2606:4700:4700::1001
2620:fe::fe
2620:fe::9
2620:fe::10
2620:fe::11
2620:fe::fe:10
2620:fe::fe:11
2620:119:35::35
2620:119:53::53
2a10:50c0::ad1:ff
2a10:50c0::ad2:ff
2a0d:2a00:1::2
2a0d:2a00:2::2
2606:1a40::
2606:1a40:1::
2a07:e340::2
EOF

  if [[ $mode == families || $mode == on ]]; then
    printf '%s\n' 2606:4700:4700::1112 2606:4700:4700::1002
  fi
}

dns_filter_nft_elements() {
  local first=1 addr
  while IFS= read -r addr; do
    [[ -n $addr ]] || continue
    if (( first )); then
      printf '%s' "$addr"
      first=0
    else
      printf ', %s' "$addr"
    fi
  done
}

dns_filter_render_unit() {
  cat <<EOF
[Unit]
Description=Omarchy family DNS egress filter
After=ufw.service network-pre.target
DefaultDependencies=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nft -f $PARENT_DNS_NFT_FILE
ExecStop=/usr/bin/nft destroy table inet $PARENT_DNS_NFT_TABLE

[Install]
WantedBy=multi-user.target
EOF
}

dns_filter_render() {
  local mode="${1:-families}"
  local v4 v6

  v4=$(dns_filter_doh_v4 "$mode" | dns_filter_nft_elements)
  v6=$(dns_filter_doh_v6 "$mode" | dns_filter_nft_elements)

  cat <<EOF
# Managed by omarchy-parent-dns. Do not edit; use sudo omarchy-parent dns.
destroy table inet $PARENT_DNS_NFT_TABLE

table inet $PARENT_DNS_NFT_TABLE {
  set doh4 {
    type ipv4_addr
    elements = { $v4 }
  }

  set doh6 {
    type ipv6_addr
    elements = { $v6 }
  }

  chain output {
    type filter hook output priority filter; policy accept;

    ip daddr 127.0.0.0/8 accept
    ip6 daddr ::1 accept

    meta skuid >= 1000 udp dport 53 drop
    meta skuid >= 1000 tcp dport 53 drop
    meta skuid >= 1000 tcp dport 853 drop
    meta skuid >= 1000 udp dport 853 drop

    meta skuid >= 1000 ip daddr @doh4 tcp dport 443 drop
    meta skuid >= 1000 ip daddr @doh4 udp dport 443 drop
    meta skuid >= 1000 ip6 daddr @doh6 tcp dport 443 drop
    meta skuid >= 1000 ip6 daddr @doh6 udp dport 443 drop
  }
}
EOF
}

dns_filter_write_file() {
  local dest="$1"
  local tmp

  tmp=$(mktemp) || return 1
  cat >"$tmp"
  install -d -m 0755 "$(dirname "$dest")"
  if install -m 0644 -T "$tmp" "$dest"; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Load the table on a booted system. In the ISO chroot only write the unit
# and enable it so the first boot applies the rules.
dns_filter_apply() {
  local mode="${1:-families}"
  local nft_cmd

  dns_filter_render "$mode" | dns_filter_write_file "$PARENT_DNS_NFT_FILE" || return 1
  dns_filter_render_unit | dns_filter_write_file "$PARENT_DNS_FILTER_UNIT" || return 1

  if dns_filter_live; then
    nft_cmd=$(command -v nft) || {
      echo "Error: nft is required to lock family DNS egress (install nftables)" >&2
      return 1
    }
    "$nft_cmd" -f "$PARENT_DNS_NFT_FILE" || return 1
    systemctl daemon-reload
    systemctl enable --now omarchy-parent-dns-filter.service
  else
    systemctl enable omarchy-parent-dns-filter.service
  fi
}

dns_filter_clear() {
  local nft_cmd

  if dns_filter_live; then
    systemctl disable --now omarchy-parent-dns-filter.service 2>/dev/null || true
  else
    systemctl disable omarchy-parent-dns-filter.service 2>/dev/null || true
  fi

  nft_cmd=$(command -v nft) || true
  if [[ -n $nft_cmd ]] && dns_filter_live; then
    "$nft_cmd" destroy table inet "$PARENT_DNS_NFT_TABLE" 2>/dev/null || true
  fi

  rm -f -- "$PARENT_DNS_NFT_FILE" "$PARENT_DNS_FILTER_UNIT"
  if dns_filter_live; then
    systemctl daemon-reload
  fi
}
