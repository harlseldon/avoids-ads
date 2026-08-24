# avoids-ads — Pi-hole para toda la casa

Bloqueo de anuncios y rastreadores a nivel DNS para la LAN y para el tailnet.

```
cliente LAN ──udp/53──▶ 192.168.100.7 ──▶ [pihole] ──▶ [coredns] ──TLS/853──▶ Cloudflare
                                             │
                                        82 562 dominios
                                          bloqueados
```

| | |
|---|---|
| Panel | http://192.168.100.7:8081 (LAN) · http://100.90.4.57:8081 (Tailscale) · http://127.0.0.1:8081 |
| Contraseña | en `.env` (`PIHOLE_PASSWORD`), generada aleatoria, fuera de git |
| DNS a repartir | `192.168.100.7` |
| Arriba/abajo | `docker compose up -d` / `docker compose down` |

## El hallazgo que define este diseño

**El ISP secuestra todo el UDP/53 saliente.** Comprobado así:

```
$ dig +short @192.0.2.1 github.com A
140.82.114.4
```

`192.0.2.1` es una dirección de documentación (RFC 5737): no existe en internet y
no puede responder nada. Que conteste significa que el router o el ISP intercepta
las consultas y las responde con su propio resolver.

Ese resolver **borra los RRSIG**, así que con `dnssec = true` y upstream
`1.1.1.1` la validación quedaba en `ABANDONED` y **todo** devolvía SERVFAIL.
Lo confirma la ausencia del flag `ad` y una respuesta DS de 80 bytes sin firma,
mientras que la misma consulta por DoH sí venía firmada.

Consecuencias, más allá de DNSSEC: mientras el DNS vaya en claro por el 53,
poner `1.1.1.1` como upstream **no sirve de nada** — el ISP ve y puede alterar
cada consulta de la casa igual que antes.

**Por eso el stack tiene dos contenedores y no uno.** CoreDNS reenvía por
DNS-over-TLS, donde el servidor se autentica con certificado: un intermediario
ya no puede suplantar a Cloudflare, y si lo intenta la conexión falla de forma
visible en vez de devolver respuestas manipuladas en silencio.

## Decisiones de arquitectura

**Red `bridge`, no `host` ni `macvlan`.**
`macvlan` sería lo ideal (IP propia en la LAN, estadísticas por cliente
perfectas), pero esta máquina sale por **wlan0** y 802.11 no admite varias MAC
por estación. `host` chocaría con systemd-resolved, que ya ocupa el :53.

**Los puertos se publican en IPs concretas, nunca en `0.0.0.0`.**
Resuelve dos cosas a la vez: el :53 deja de competir con el stub de
systemd-resolved (`127.0.0.53`, `127.0.0.54`, `172.17.0.1`) — así que **no hubo
que tocar la configuración DNS del sistema** — y Pi-hole no queda expuesto como
open resolver, algo que importa porque `listeningMode: ALL` permite cualquier
origen.

**Panel en el 8081, no en el 80.** Deja el :80 del host libre para un futuro
reverse proxy.

**Versiones fijadas, no `:latest`.** Pi-hole v6 rompió toda la configuración de
v5; un `pull` a ciegas puede dejar la casa sin DNS. Actualizar es cambiar el tag
a conciencia.

**Sin `NET_ADMIN`.** Esa capability solo hace falta si Pi-hole hace de servidor
DHCP, y aquí el DHCP lo sigue dando el router.

**`cloudflared proxy-dns` no es opción**: Cloudflare eliminó esa función en
cloudflared 2026.2.0.

## Configuración por variables de entorno

Pi-hole v6 recomienda configurar por `FTLCONF_*`, y es lo que hace este stack
reproducible desde git. **Contrapartida: lo que se fija por entorno queda de
solo lectura en la interfaz web.** Para cambiar upstreams, DNSSEC, etc.:

```bash
vim .env          # o docker-compose.yml
docker compose up -d --force-recreate
```

Lo que **sí** se administra desde la web (no está fijado por entorno): listas de
bloqueo, whitelist/blacklist, grupos y clientes.

## Estado verificado

```
dominio normal            github.com        → 140.82.112.3     ✓
anuncio bloqueado         doubleclick.net   → 0.0.0.0          ✓
DNSSEC válido             cloudflare.com    → flags: ... ad    ✓
DNSSEC roto rechazado     dnssec-failed.org → SERVFAIL         ✓
vía Tailscale             example.com       → responde         ✓
systemd-resolved intacto  host resuelve solo                   ✓
stack jellyfin intacto                                          ✓
```

## Pendiente — pasos manuales fuera de este repo

Sin esto Pi-hole funciona pero **nadie lo usa todavía**.

**1. Abrir el 53 en ufw.** ufw está activo en este equipo:

```bash
sudo ufw allow from 192.168.100.0/24 to any port 53 comment 'Pi-hole DNS LAN'
sudo ufw route allow in on tailscale0 to any port 53
```

La forma `route` es necesaria para el tailnet: la integración `ufw-docker` de
`/etc/ufw/after.rules` descarta las conexiones reenviadas hacia subredes de
contenedores salvo que el origen sea la LAN. Es el mismo detalle que ya apareció
con Jellyfin en el 8096.

**2. Reservar la IP del servidor en el router.**
`192.168.100.7` es una **concesión DHCP**, no una IP estática (`ip route` la
marca `proto dhcp`). Si cambia, la casa entera se queda sin DNS. Hay que fijarla
por reserva DHCP en el router (o dejarla estática en NetworkManager).

**3. Repartir Pi-hole como DNS.** En el router (192.168.100.1), poner
`192.168.100.7` como servidor DNS del DHCP.

> **No pongas un DNS secundario público** (8.8.8.8 y similares). Los clientes no
> usan el secundario solo cuando el primario falla — lo consultan cuando les
> conviene, y esas consultas se saltan el filtro. O solo Pi-hole, o nada.
> El riesgo es real (si esta máquina cae, no hay DNS en casa), pero está
> acotado: el equipo ya está siempre encendido y el contenedor arranca solo.

**4. El agujero de IPv6.** El router anuncia DNS por IPv6 (`fe80::1`) además del
IPv4, y este equipo de hecho ya lo está usando de forma preferente. **Los
clientes preferirán el DNS IPv6 del router y se saltarán Pi-hole por completo.**
Es la causa número uno de "instalé Pi-hole y no bloquea nada". Opciones, de
mejor a peor:

- Que el router anuncie como DNS IPv6 la dirección IPv6 de este equipo.
- Desactivar IPv6 en el router, si el ISP lo permite.
- Asumir que el bloqueo será parcial.

Después de tocar el router, comprobar desde un cliente que las consultas
aparecen en el panel de Pi-hole.

## Ideas para más adelante

- **Estadísticas por cliente.** En bridge, los clientes de la misma /24 sí
  conservan su IP real; los del tailnet (otra subred) se ven todos como el
  gateway de Docker. Si algún día esta máquina pasa a cable, `macvlan` lo
  arregla del todo.
- **Split-horizon para `vip.harlseldon.com`.** Resolverlo a la IP local haría
  que la familia en casa llegue a Jellyfin sin pasar por el Cloudflare Tunnel
  (menos latencia, y menos tráfico de vídeo por Cloudflare, cuyos ToS §2.8 lo
  desaconsejan). **Requiere antes un reverse proxy local en el 443 con
  certificado válido** — apuntar el nombre a `192.168.100.7` sin eso rompería el
  acceso, porque ahí no hay nada escuchando en 443.
- **Resolución recursiva propia** con unbound, para no depender de Cloudflare.
