#!/usr/bin/env bash
# Comprueba de punta a punta que Pi-hole está filtrando la casa.
# Uso: ./check.sh        (tarda ~1 min: escanea la LAN y prueba el DHCP del ONT)
#
# Cada línea es ✓ / ✗ / ⚠. Un ✗ significa que algo dejó de filtrar.

cd "$(dirname "$0")"
P=192.168.100.7
DB=/etc/pihole/pihole-FTL.db
ok()   { printf '  \e[32m✓\e[0m %s\n' "$*"; }
bad()  { printf '  \e[31m✗\e[0m %s\n' "$*"; }
warn() { printf '  \e[33m⚠\e[0m %s\n' "$*"; }
q()    { docker run --rm --net=host alpine nslookup -type=a "$1" "$2" 2>/dev/null | awk '/^Address: /{a=$2} END{print a}'; }
sql()  { docker exec pihole pihole-FTL sqlite3 "$DB" "$1" 2>/dev/null; }

echo "Servicio"
for c in pihole avoids-doh avoids-dhcp; do
  s=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
  [ "$s" = running ] && ok "$c en marcha" || bad "$c: ${s:-no existe}"
done
ip -4 -o addr show enp3s0 | grep -q "$P/24" && ! ip -4 -o addr show enp3s0 | grep -q dynamic \
  && ok "este equipo tiene $P fija" || bad "este equipo NO tiene $P fija — Pi-hole inalcanzable desde la LAN"

echo "Resolución"
[ -n "$(q github.com $P)" ] && [ "$(q github.com $P)" != 0.0.0.0 ] && ok "resuelve dominios normales" || bad "no resuelve github.com"
[ "$(q doubleclick.net $P)" = 0.0.0.0 ]            && ok "bloquea anuncios"             || bad "doubleclick.net NO bloqueado"
[ "$(q mozilla.cloudflare-dns.com $P)" = 0.0.0.0 ] && ok "bloquea DoH de navegadores"   || bad "DoH de Firefox NO bloqueado"
[ -n "$(q github.com 100.90.4.57)" ]                && ok "responde por Tailscale"       || bad "no responde por Tailscale"
docker exec pihole dig +dnssec +timeout=6 @127.0.0.1 cloudflare.com A 2>/dev/null | grep -q 'flags:.* ad' \
  && ok "DNSSEC validando (DoT esquiva el secuestro del ISP)" || bad "DNSSEC sin flag ad — revisar avoids-doh"

echo "Reparto en la casa"
off=$(docker run --rm --net=host --cap-add=NET_ADMIN --cap-add=NET_RAW alpine sh -c \
  'apk add -q nmap nmap-scripts >/dev/null 2>&1; timeout 40 nmap --script broadcast-dhcp-discover -e enp3s0 2>&1' \
  | grep -c 'Server Identifier: 192.168.100.1')
[ "$off" = 0 ] && ok "el DHCP del ONT sigue apagado" || bad "el ONT volvió a repartir DHCP — la casa dejó de usar Pi-hole"
leak=$(docker run --rm --net=host alpine nslookup -type=a caliente.mx fe80::1%enp3s0 2>/dev/null | awk '/^Address: /{a=$2} END{print a}')
[ -z "$leak" ] || [ "$leak" = 0.0.0.0 ] && ok "el ONT no ofrece DNS por IPv6" \
  || warn "el ONT anuncia DNS por IPv6 (fe80::1) y no filtra: los equipos que lo usen se saltan Pi-hole"

echo "Equipos de la LAN (últimas 24 h)"
for ip in $(docker run --rm --net=host --cap-add=NET_RAW --cap-add=NET_ADMIN alpine sh -c \
    'apk add -q nmap >/dev/null 2>&1; nmap -sn -PR 192.168.100.0/24 2>&1' | grep -oE '192\.168\.100\.[0-9]+' | sort -t. -k4 -n -u); do
  [ "$ip" = 192.168.100.1 ] || [ "$ip" = "$P" ] && continue
  r=$(sql "select count(*)||' consultas, '||coalesce(sum(status in (1,4,5,9,10,11)),0)||' bloqueadas' from queries where client='$ip' and timestamp > strftime('%s','now','-24 hours');")
  n=$(awk -v i="$ip" '$3==i && $4!="*"{print $4}' dhcp-leases/dnsmasq.leases 2>/dev/null)
  case "$r" in 0\ *) warn "$ip ${n:+($n) }no ha consultado a Pi-hole — concesión vieja del ONT o DNS propio" ;;
               *)    ok   "$ip ${n:+($n) }$r" ;; esac
done
