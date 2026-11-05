#!/usr/bin/env bash
# Opt-in strict firewall with timed recovery. Requires direct SSH access.
set -Eeuo pipefail
[[ $(id -u) -eq 0 ]] || exit 1
# shellcheck disable=SC1091
source /etc/x-ui/autodeploy-public.env
DIR=/root/xui-firewall-recovery
mkdir -p "$DIR"; chmod 700 "$DIR"
case "${1:-}" in
  apply)
    if iptables -S INPUT | grep -q -- '-j XUI_AUTOGUARD'; then
      echo 'Already applied'; exit 1
    fi
    iptables-save > "$DIR/ipv4.rules"
    ip6tables-save > "$DIR/ipv6.rules"
    cat > "$DIR/restore.sh" <<'RESTORE'
#!/usr/bin/env bash
set -euo pipefail
iptables-restore < /root/xui-firewall-recovery/ipv4.rules
ip6tables-restore < /root/xui-firewall-recovery/ipv6.rules
RESTORE
    chmod 700 "$DIR/restore.sh"
    systemd-run --unit=xui-autoguard-recovery --on-active=10min /bin/bash "$DIR/restore.sh"
    for tool in iptables ip6tables; do
      "$tool" -N XUI_AUTOGUARD
      "$tool" -A XUI_AUTOGUARD -i lo -j ACCEPT
      "$tool" -A XUI_AUTOGUARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      if [[ "$tool" == iptables ]]; then
        "$tool" -A XUI_AUTOGUARD -p icmp -j ACCEPT
      else
        "$tool" -A XUI_AUTOGUARD -p ipv6-icmp -j ACCEPT
      fi
      "$tool" -A XUI_AUTOGUARD -p tcp -m multiport --dports "$SSH_PORT",80,"$VPN_PORT" -j ACCEPT
      "$tool" -A XUI_AUTOGUARD -j DROP
      "$tool" -I INPUT 1 -j XUI_AUTOGUARD
    done
    echo 'Applied. Test NEW direct SSH session and VPN externally within 10 minutes.'
    echo 'Then run: sudo bash scripts/harden_firewall.sh confirm'
    ;;
  confirm)
    iptables -C INPUT -j XUI_AUTOGUARD
    ip6tables -C INPUT -j XUI_AUTOGUARD
    systemctl is-active --quiet xui-autoguard-recovery.timer || {
      echo 'Rollback timer is not active; do not save'; exit 1;
    }
    systemctl stop xui-autoguard-recovery.timer
    netfilter-persistent save
    echo 'Strict firewall saved to persistent IPv4 and IPv6 rules.'
    ;;
  *) echo 'Usage: harden_firewall.sh apply|confirm'; exit 2 ;;
esac
