#!/bin/sh
# Установщик: Xray с балансерами из подписки Remnawave + SSClash (Mihomo)
#
# Установка:
#   wget -qO- https://raw.githubusercontent.com/Connecta-VPS/ConnectaRouter/main/install.sh | sh -s -- 'ССЫЛКА_ПОДПИСКИ'
# Сменить подписку: запустить ту же команду с новой ссылкой.
# Свои исключения (без VPN): connecta add сайт.ru | connecta del сайт.ru | connecta list
# Удаление:
#   wget -qO- https://raw.githubusercontent.com/Connecta-VPS/ConnectaRouter/main/install.sh | sh -s -- uninstall

set -e

SUB_URL="$1"
DIR=/etc/xray-sub
CLASH_DIR=/opt/clash

say() { echo ">>> $*"; }
die() { echo "!!! $*" >&2; exit 1; }

# ---------- Удаление ----------
if [ "$SUB_URL" = "uninstall" ]; then
  /etc/init.d/xray-sub stop 2>/dev/null || true
  /etc/init.d/xray-sub disable 2>/dev/null || true
  rm -f /etc/init.d/xray-sub /usr/bin/xray-sub-update.sh /usr/bin/connecta
  rm -rf "$DIR" /tmp/xray-sub /usr/share/xray-sub
  sed -i '/xray-sub-update.sh/d' /etc/crontabs/root 2>/dev/null || true
  /etc/init.d/cron restart 2>/dev/null || true
  say "Xray-подписка удалена. SSClash оставлен, его можно удалить из LuCI."
  exit 0
fi

case "$SUB_URL" in
  http://*|https://*) ;;
  *) die "Укажите ссылку подписки: sh -s -- 'https://...'" ;;
esac

# ---------- 1. Пакеты ----------
if command -v apk >/dev/null 2>&1; then
  say "Устанавливаю пакеты (apk)..."
  apk update >/dev/null
  apk add xray-core jq curl >/dev/null
elif command -v opkg >/dev/null 2>&1; then
  say "Устанавливаю пакеты (opkg)..."
  opkg update >/dev/null
  opkg install xray-core jq curl >/dev/null
else
  die "Не найден менеджер пакетов (apk/opkg). Это точно OpenWrt?"
fi
command -v xray >/dev/null 2>&1 || die "xray-core не установился"
command -v jq   >/dev/null 2>&1 || die "jq не установился"

# Стандартная служба xray из пакета не нужна
/etc/init.d/xray stop 2>/dev/null || true
/etc/init.d/xray disable 2>/dev/null || true

# ---------- 2. SSClash ----------
if [ ! -x /etc/init.d/clash ]; then
  say "Устанавливаю SSClash и ядро Mihomo..."
  wget --no-proxy -qO- https://github.com/zerolabnet/SSClash/raw/refs/heads/main/install-ssclash.sh | ash
  [ -x /etc/init.d/clash ] || die "SSClash не установился"
else
  say "SSClash уже установлен"
fi

# ---------- 3. Настройки ----------
mkdir -p "$DIR"
MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || echo unknown)
HWID="openwrt-$(echo "$MAC" | md5sum | cut -c1-16)"
cat > "$DIR/settings" <<EOF
SUB_URL='$SUB_URL'
HWID='$HWID'
BASE_PORT=10808
MARK=2
EOF
say "HWID роутера: $HWID"

# ---------- 4. Шаблон конфига SSClash ----------
# Строка #PROXIES# заменяется списком балансеров из подписки
cat > "$DIR/clash-template.yaml" <<'EOT'
mode: rule
tproxy-port: 7894
ipv6: false
log-level: error
allow-lan: true
unified-delay: true
tcp-concurrent: true
external-controller: 0.0.0.0:9090
external-ui: ./ui
external-ui-url: 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip'

dns:
  enable: true
  listen: 0.0.0.0:7874
  ipv6: false
  default-nameserver:
    - https://77.88.8.8/dns-query
    - https://8.8.8.8/dns-query
  proxy-server-nameserver:
    - https://77.88.8.8/dns-query
    - https://8.8.8.8/dns-query
  direct-nameserver:
    - https://77.88.8.8/dns-query
    - https://8.8.8.8/dns-query
  nameserver:
    - https://8.8.8.8/dns-query
    - https://8.8.4.4/dns-query

profile:
  store-selected: true
  store-fake-ip: true

routing-mark: 2

sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
  skip-domain:
    - 'Mijia Cloud'
    - '+.lan'
    - '+.local'
    - '+.push.apple.com'
    - '+.apple.com'

proxies:
#PROXIES#

proxy-groups:
  - name: 🛡️ VPN
    type: select
    include-all: true

  - name: 📺 Youtube
    type: select
    proxies:
      - 🛡️ VPN
    include-all: true

# Раздельное туннелирование (что напрямую, что через VPN, что блокировать)
# делает Xray по правилам из вашего Xray JSON в Remnawave — как в Happ.
# Здесь: локальная сеть, Steam и игры напрямую, выбор страны для YouTube.
rule-providers:
  private-domains: {behavior: domain, type: http, format: mrs, interval: 2592000, path: ./ruleset/geosite-private.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/private.mrs'}
  private-ips: {behavior: ipcidr, type: http, format: mrs, interval: 2592000, path: ./ruleset/geoip-private.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/mihomo/private.mrs'}
  youtube: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/youtube.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/youtube.mrs'}
  steam: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/steam.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/steam.mrs'}
  epicgames: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/epicgames.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/epicgames.mrs'}
  riot: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/riot.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/riot.mrs'}
  origin: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/origin.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/origin.mrs'}
  escapefromtarkov: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/escapefromtarkov.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/escapefromtarkov.mrs'}
  faceit: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/faceit.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/faceit.mrs'}

rules:
  - RULE-SET,private-ips,DIRECT,no-resolve
  - IP-CIDR,::/0,REJECT-DROP,no-resolve
  - RULE-SET,private-domains,DIRECT
  # Steam и игры — без VPN (домены + игровые серверы Valve и Riot по сетям)
  - RULE-SET,steam,DIRECT
  - RULE-SET,epicgames,DIRECT
  - RULE-SET,riot,DIRECT
  - RULE-SET,origin,DIRECT
  - RULE-SET,escapefromtarkov,DIRECT
  - RULE-SET,faceit,DIRECT
  - IP-ASN,32590,DIRECT,no-resolve
  - IP-ASN,6507,DIRECT,no-resolve
  - RULE-SET,youtube,📺 Youtube
  - MATCH,🛡️ VPN
EOT

# ---------- 5. Скрипт обновления подписки ----------
cat > /usr/bin/xray-sub-update.sh <<'EOS'
#!/bin/sh
DIR=/etc/xray-sub
. "$DIR/settings"
CLASH_CONF=/opt/clash/config.yaml
TMP_DIR=/tmp/xray-sub
mkdir -p "$TMP_DIR"

log() { logger -t xray-sub "$*"; echo "$*"; }

# Базы geosite/geoip для правил из Xray JSON (те же, что у Happ с роутингом roscomvpn)
GEO_DIR=/usr/share/xray-sub
export XRAY_LOCATION_ASSET="$GEO_DIR"
mkdir -p "$GEO_DIR"
geo_get() {
  if [ ! -s "$GEO_DIR/$1" ] || [ -n "$(find "$GEO_DIR/$1" -mtime +7 2>/dev/null)" ]; then
    curl -fsSL --max-time 120 "$2" -o "$TMP_DIR/$1.new" && [ -s "$TMP_DIR/$1.new" ] \
      && mv "$TMP_DIR/$1.new" "$GEO_DIR/$1" && log "Обновлена база $1"
  fi
}
fetch() {
  curl -fsSL --max-time 30 -A "Happ/3.13.0" \
    -H "x-hwid: $HWID" -H "x-device-os: Linux" \
    -H "x-ver-os: OpenWrt" -H "x-device-model: Router" \
    "$1" -o "$TMP_DIR/raw" 2>/dev/null
}

is_json() { jq -e 'type == "array" or type == "object"' "$TMP_DIR/raw" >/dev/null 2>&1; }

if ! { fetch "$SUB_URL" && is_json; }; then
  if ! { fetch "${SUB_URL%/}/v2ray-json" && is_json; }; then
    log "Ошибка: подписка не отдала Xray JSON. Проверьте ссылку и лимит устройств."
    exit 1
  fi
fi

# Базы geo скачиваются, только если правила в подписке на них ссылаются
grep -q '"geosite:' "$TMP_DIR/raw" && geo_get geosite.dat "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/geosite.dat"
grep -q '"geoip:' "$TMP_DIR/raw" && geo_get geoip.dat "https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/geoip.dat"

# Список балансеров и порты
jq -r --argjson port "$BASE_PORT" '(if type == "array" then . else [.] end)
  | to_entries[] | "\($port + .key): \(.value.remarks // "без имени")"' \
  "$TMP_DIR/raw" > "$TMP_DIR/list.txt"

# Все балансеры в одном Xray: у каждого свой вход (порт) и свои теги
jq --argjson port "$BASE_PORT" --argjson mark "$MARK" '
  def pfx($p): if . == null then null else $p + . end;
  (if type == "array" then . else [.] end)
  | (.[0].routing.domainStrategy // "AsIs") as $ds
  | [ to_entries[] | .key as $i | .value as $c | "c\($i)-" as $p | {
      inbound: {tag: "in-\($i)", listen: "127.0.0.1", port: ($port + $i), protocol: "socks",
        settings: {auth: "noauth", udp: true},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}},
      outbounds: [ ($c.outbounds // [])[]
        | .tag |= pfx($p)
        | if .proxySettings.tag then .proxySettings.tag |= pfx($p) else . end
        | .streamSettings = ((.streamSettings // {}) | .sockopt = ((.sockopt // {}) + {mark: $mark}))
        | if .streamSettings.sockopt.dialerProxy then .streamSettings.sockopt.dialerProxy |= pfx($p) else . end ],
      balancers: [ ($c.routing.balancers // [])[]
        | .tag |= pfx($p) | .selector |= map($p + .)
        | if .fallbackTag then .fallbackTag |= pfx($p) else . end ],
      rules: ([ ($c.routing.rules // [])[] | select(.inboundTag == null)
        | .inboundTag = ["in-\($i)"]
        | if .outboundTag then .outboundTag |= pfx($p) else . end
        | if .balancerTag then .balancerTag |= pfx($p) else . end ]
        + [ {type: "field", inboundTag: ["in-\($i)"],
             outboundTag: (($c.outbounds // [])[0].tag | if . == null then "direct" else $p + . end)} ]),
      obs: (($c.observatory.subjectSelector // []) | map($p + .)),
      bobs: (($c.burstObservatory.subjectSelector // []) | map($p + .)),
      obsCfg: $c.observatory,
      bobsCfg: $c.burstObservatory
    } ] as $all
  | {
      log: {loglevel: "warning"},
      inbounds: [$all[].inbound],
      outbounds: ([$all[].outbounds[]] + [{tag: "direct", protocol: "freedom", streamSettings: {sockopt: {mark: $mark}}}]),
      routing: {domainStrategy: $ds, balancers: [$all[].balancers[]], rules: [$all[].rules[]]}
    }
  | if ([$all[].obs[]] | length) > 0
      then .observatory = ([$all[].obsCfg | select(. != null)][0] + {subjectSelector: [$all[].obs[]]}) else . end
  | if ([$all[].bobs[]] | length) > 0
      then .burstObservatory = ([$all[].bobsCfg | select(. != null)][0] + {subjectSelector: [$all[].bobs[]]}) else . end
' "$TMP_DIR/raw" > "$TMP_DIR/config.json" || { log "Ошибка: не удалось разобрать JSON"; exit 1; }

if ! xray run -test -c "$TMP_DIR/config.json" >"$TMP_DIR/test.log" 2>&1; then
  log "Ошибка: Xray не принял конфиг, оставляю старый. Подробности: $TMP_DIR/test.log"
  exit 1
fi

# Конфиг SSClash: шаблон + по одному прокси на каждый балансер
jq -r --argjson port "$BASE_PORT" '(if type == "array" then . else [.] end)
  | to_entries[]
  | "  - {name: \((.value.remarks // "Сервер \(.key)") | tojson), type: socks5, server: 127.0.0.1, port: \($port + .key), udp: true}"' \
  "$TMP_DIR/raw" > "$TMP_DIR/proxies.yaml"
# Личные исключения: домены из /etc/connecta/direct.list идут без VPN (по одному на строку)
: > "$TMP_DIR/direct.yaml"
if [ -f /etc/connecta/direct.list ]; then
  sed 's/#.*//; s/[[:space:]]//g; /^$/d' /etc/connecta/direct.list \
    | while read -r d; do echo "  - DOMAIN-SUFFIX,$d,DIRECT"; done > "$TMP_DIR/direct.yaml"
fi
awk -v f="$TMP_DIR/proxies.yaml" -v g="$TMP_DIR/direct.yaml" '
  /^#PROXIES#$/ { while ((getline l < f) > 0) print l; next }
  { print }
  /^rules:$/ { while ((getline l < g) > 0) print l }' \
  "$DIR/clash-template.yaml" > "$TMP_DIR/clash.yaml"

if ! cmp -s "$TMP_DIR/config.json" "$DIR/config.json"; then
  cp "$TMP_DIR/config.json" "$DIR/config.json"
  /etc/init.d/xray-sub enable
  /etc/init.d/xray-sub restart 2>/dev/null
  log "Xray: подписка обновлена"
fi

if [ -d /opt/clash ] && ! cmp -s "$TMP_DIR/clash.yaml" "$CLASH_CONF"; then
  cp "$TMP_DIR/clash.yaml" "$CLASH_CONF"
  /etc/init.d/clash restart 2>/dev/null
  log "SSClash: список серверов обновлён"
fi

log "Готово. Серверы: $(tr '\n' ';' < "$TMP_DIR/list.txt")"
EOS
chmod +x /usr/bin/xray-sub-update.sh

# ---------- 5b. Команда connecta для исключений ----------
cat > /usr/bin/connecta <<'EOC'
#!/bin/sh
# connecta add <сайт>   — сайт пойдёт без VPN
# connecta del <сайт>   — снова через VPN
# connecta list         — список исключений
LIST=/etc/connecta/direct.list
mkdir -p /etc/connecta; touch "$LIST"

clean() {  # https://www.site.ru/page?x=1 -> site.ru
  echo "$1" | tr 'A-Z' 'a-z' | sed -E 's#^[a-z]+://##; s#[/:?\#].*$##; s#^www\.##'
}
apply() { /usr/bin/xray-sub-update.sh >/dev/null 2>&1 && echo "Применено." || echo "Сохранено, применится при следующем обновлении подписки."; }

case "$1" in
  add)
    [ -n "$2" ] || { echo "Пример: connecta add sberbank.ru"; exit 1; }
    shift
    for a in "$@"; do
      d=$(clean "$a"); [ -n "$d" ] || continue
      if grep -qx "$d" "$LIST"; then echo "Уже в списке: $d"; else echo "$d" >> "$LIST"; echo "Без VPN: $d"; fi
    done
    apply ;;
  del|rm)
    [ -n "$2" ] || { echo "Пример: connecta del sberbank.ru"; exit 1; }
    shift
    for a in "$@"; do
      d=$(clean "$a")
      if grep -qx "$d" "$LIST"; then sed -i "/^$(echo "$d" | sed 's/\./\\./g')\$/d" "$LIST"; echo "Снова через VPN: $d"; else echo "Нет в списке: $d"; fi
    done
    apply ;;
  list|ls)
    if [ -s "$LIST" ]; then echo "Без VPN:"; sed 's/^/  • /' "$LIST"; else echo "Список исключений пуст."; fi ;;
  *)
    echo "connecta add <сайт>   — сайт пойдёт без VPN"
    echo "connecta del <сайт>   — снова через VPN"
    echo "connecta list         — список исключений" ;;
esac
EOC
chmod +x /usr/bin/connecta

# ---------- 6. Служба Xray ----------
cat > /etc/init.d/xray-sub <<'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
	[ -f /etc/xray-sub/config.json ] || return 0
	procd_open_instance
	procd_set_param command /usr/bin/xray run -c /etc/xray-sub/config.json
	procd_set_param env XRAY_LOCATION_ASSET=/usr/share/xray-sub
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
EOF
chmod +x /etc/init.d/xray-sub
/etc/init.d/xray-sub enable

# ---------- 7. Автообновление подписки (каждые 6 часов) ----------
touch /etc/crontabs/root
sed -i '/xray-sub-update.sh/d' /etc/crontabs/root
echo "0 */6 * * * /usr/bin/xray-sub-update.sh >/dev/null 2>&1" >> /etc/crontabs/root
/etc/init.d/cron enable 2>/dev/null || true
/etc/init.d/cron restart 2>/dev/null || true

# ---------- 8. Первый запуск ----------
say "Загружаю подписку..."
set +e
/usr/bin/xray-sub-update.sh || die "Подписка не загрузилась. Проверьте ссылку и запустите /usr/bin/xray-sub-update.sh ещё раз."
/etc/init.d/clash enable 2>/dev/null
/etc/init.d/clash start 2>/dev/null

sleep 3
IP=$(curl -s --max-time 10 -x socks5h://127.0.0.1:10808 https://ifconfig.me)
if [ -n "$IP" ]; then
  say "Всё работает. IP через VPN: $IP"
else
  say "Xray запущен, но проверка IP не прошла. Посмотрите: logread | grep xray"
fi
LANIP=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
say "Панель управления: http://${LANIP:-IP-роутера}:9090/ui"
say "Сайт без VPN: connecta add сайт.ru   (список: connecta list)"
