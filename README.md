# avoids-ads — Pi-hole para toda la casa

Bloqueo de anuncios y rastreadores a nivel DNS para la LAN y para el tailnet.

```
                    [dnsmasq] ──DHCP──▶ "tu DNS es 192.168.100.7"
                        │                        │
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
vía Tailscale*            example.com       → responde         ✓
systemd-resolved intacto  host resuelve solo                   ✓
stack jellyfin intacto                                          ✓
```

\* Probado desde un contenedor, cuyo origen es `172.x`: confirma que Pi-hole
responde en la IP de Tailscale, **no** que un peer remoto atraviese el firewall.
Eso depende del paso 1 y hay que comprobarlo desde otro dispositivo del tailnet.

## El ONT de Totalplay no deja repartir DNS

El plan original era decirle al router que anunciara `192.168.100.7` como DNS.
No se puede: en el HG8145X6, `LAN → DHCP Server` tiene **`Primary DNS Server` y
`Secondary DNS Server` bloqueados**, en gris, y no hay combinación que los
libere. Se descartó una por una:

- Con `Enable DHCP Relay` **marcado** — el estado de fábrica — siguen en gris.
- Con el relay **desmarcado** y el servidor DHCP activo, siguen en gris.
- Recargando la página a fondo, siguen en gris.

La cuenta usada es `root`, así que no es cuestión de permisos de la interfaz.
La conexión principal es `1_TR069_INTERNET_R_VID_400`: el prefijo `TR069`
indica que Totalplay la gestiona en remoto por CWMP, así que lo más probable es
que el bloqueo venga del ACS del ISP o del firmware que ellos publican.

**De ahí el contenedor `dhcp`.** Si el router no puede decir quién es el DNS de
la casa, el DHCP lo servimos nosotros.

## Puesta en marcha

Los tres pasos van en este orden. El único momento delicado es el 2→3, donde la
red se queda unos segundos sin servidor DHCP; los equipos ya conectados no lo
notan porque conservan su concesión.

**1. IP fija para el servidor.** Sin esto, el equipo dependería para su propia
dirección de un servidor DHCP que es él mismo:

```bash
sudo cp 10-wlan0-static.network /etc/systemd/network/
sudo networkctl reload && sudo networkctl reconfigure wlan0
ip -4 -o addr show wlan0     # debe seguir siendo 192.168.100.7/24
ping -c2 192.168.100.1       # y seguir habiendo salida
```

**2. Quitarle el DHCP al ONT.** En `192.168.100.1` → `LAN` → `DHCP Server`,
desmarcar **`Enable Primary DHCP Server`** y aplicar. Nada más de esa pantalla.

**3. Levantar el nuestro:**

```bash
docker compose up -d dhcp
docker logs -f avoids-dhcp    # se ven los DISCOVER/OFFER/ACK en vivo
```

Para comprobarlo, reconecta la wifi en un móvil y mira que reciba
`192.168.100.7` como DNS. Sus consultas deben aparecer en el panel de Pi-hole
con su IP.

### Volver atrás

```bash
docker compose stop dhcp
sudo rm /etc/systemd/network/10-wlan0-static.network
sudo networkctl reload && sudo networkctl reconfigure wlan0
```

y volver a marcar `Enable Primary DHCP Server` en el ONT.

### Lo que cuesta este montaje

- **Punto único de fallo.** Si este equipo se apaga, la casa se queda sin DNS
  **y** sin repartir direcciones. Antes el ONT hacía de colchón. Se aceptó a
  conciencia a cambio de cubrir la casa entera.
- **Depende de la wifi**, porque este equipo entra por `wlan0`, no por cable.
- **Los clientes salen como IP, no como nombre**, en el panel de Pi-hole. El
  conditional forwarding apunta al ONT (`FTLCONF_dns_revServers`) y su tabla de
  DHCP queda vacía al quitarle el servicio. Para los pocos equipos que importen,
  lo práctico es darlos de alta a mano en Pi-hole.
- **IPv6 no es un pendiente menor: es el bloqueo principal.** Ver abajo.

## IPv6 deja el DHCP sin efecto

Tras montar el DHCP, ningún cliente lo usaba. La causa no era el firewall, ni
dnsmasq, ni el aislamiento de la wifi — todas se descartaron con capturas. Es
que **los dispositivos no piden IPv4 en absoluto**.

Captura de 5 minutos en `wlan0` durante dos reconexiones completas de un
Android, filtrando DHCP y Router Advertisements:

```
router solicitations:  2     ← el móvil pidiendo red
router advertisements: 2     ← el ONT contestando
paquetes DHCPv4:       0     ← ni uno
```

El teléfono queda con tres direcciones, todas IPv6, ninguna IPv4:

```
fe80::6489:e6ff:fe84:514f
2806:2f0:aee0:3b8:6489:e6ff:fe84:514f
2806:2f0:aee0:3b8:449e:4d69:42f3:565a
```

El ONT le da prefijo por SLAAC y el DNS (`fe80::1`) dentro del propio Router
Advertisement. Con eso Android tiene internet completo y nunca llega a pedir
una dirección IPv4, así que el servidor DHCP —que funciona— no tiene a quién
servir.

**La solución es apagar el IPv6 de la LAN en el ONT** (`LAN → DHCPv6 Server`).
Sin RA no hay `fe80::1` como DNS, y los clientes vuelven a pedir IPv4, que es
donde dnsmasq ya está esperando.

Anunciar nosotros un DNS por IPv6 **no sirve**: el RDNSS viaja dentro del Router
Advertisement del router, no en el DHCPv6. El ONT seguiría anunciando el suyo y
los clientes se quedarían con ambos, usando el que les conviniera — bloqueo
intermitente e imposible de diagnosticar.

### Lo que se descartó por el camino

- **Firewall.** Faltaba `ufw allow in on wlan0 to any port 67 proto udp` y se
  añadió, pero el silencio siguió. Nota: va sin `route`, porque dnsmasq corre
  en `network_mode: host` — al revés que el 53 de Tailscale.
- **Aislamiento de clientes en la wifi.** Descartado: el escaneo ARP ve al resto
  de dispositivos, y la router solicitation del móvil llega a esta interfaz.
- **Que el ONT siguiera repartiendo DHCP.** Descartado: la casilla se quedó
  desmarcada y no la revirtió el ACS.
- **Concesiones viejas.** Ciertas, pero secundarias: el ONT daba 72 h, así que
  los equipos conservan direcciones antiguas mucho tiempo. Reconectar la wifi no
  basta para forzar una petición nueva; hay que *olvidar la red*.

### Si Pi-hole se cae y el host se queda sin resolver

El host se reparte a sí mismo Pi-hole como DNS. Para recuperarlo en el momento,
sin tocar ficheros:

```bash
sudo resolvectl dns wlan0 1.1.1.1
```

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
