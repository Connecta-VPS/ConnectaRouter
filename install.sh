#!/bin/sh
# Установщик: Xray с балансерами из подписки Remnawave + SSClash (Mihomo)
#
# Установка:
#   wget -qO- https://raw.githubusercontent.com/Connecta-VPS/ConnectaRouter/main/install.sh | sh -s -- 'ССЫЛКА_ПОДПИСКИ'
# Сменить подписку: запустить ту же команду с новой ссылкой.
# Свои исключения (без VPN): connecta add сайт.ru | connecta del сайт.ru | connecta list
# Удаление:
#   wget -qO- https://raw.githubusercontent.com/Connecta-VPS/ConnectaRouter/main/install.sh | sh -s -- uninstall
#
# АВТООБНОВЛЕНИЕ: роутеры раз в сутки (ночью) проверяют этот файл на GitHub.
# Чтобы обновление доехало до всех — УВЕЛИЧЬТЕ число VERSION ниже (например, дата + номер).
# Если после обновления VPN на роутере не заработает, роутер сам откатится на прошлую версию.

VERSION=2026111504

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
  rm -f /etc/init.d/xray-sub /usr/bin/xray-sub-update.sh /usr/bin/connecta /usr/bin/connecta-autoupdate.sh
  rm -rf "$DIR" /tmp/xray-sub /usr/share/xray-sub
  sed -i '/xray-sub-update.sh/d; /connecta-autoupdate/d' /etc/crontabs/root 2>/dev/null || true
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
  curl -fsSL --retry 3 -o /tmp/install-ssclash.sh \
    https://raw.githubusercontent.com/zerolabnet/SSClash/main/install-ssclash.sh \
    || die "Не удалось скачать установщик SSClash (нет доступа к GitHub?)"
  ash /tmp/install-ssclash.sh || true
  rm -f /tmp/install-ssclash.sh
  [ -x /etc/init.d/clash ] || die "SSClash не установился. Смотрите вывод выше."
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
# ⚠️ ЭТОТ ФАЙЛ СОБИРАЕТСЯ АВТОМАТИЧЕСКИ при каждом обновлении подписки — ручные правки будут стёрты!
# Сайты без VPN:        connecta add сайт.ru        (список: connecta list)
# Свои группы/правила:  /etc/connecta/groups.yaml и /etc/connecta/rules.yaml
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
#CUSTOM_GROUPS#
  - name: 🛡️ VPN
    type: select
    proxies:
      - ♻️ Авто с резервом
      - ⚡ Самый быстрый
    include-all: true

  # Работает через «🌀 АВТО-ВЫБОР» (первый в подписке). Если он перестал отвечать —
  # сам переключается на следующую живую страну, а когда АВТО оживёт — возвращается.
  - name: ♻️ Авто с резервом
    type: fallback
    include-all: true
    exclude-filter: '(?i)Россия|БС'
    url: 'https://www.gstatic.com/generate_204'
    interval: 120
    timeout: 5000

  # Постоянно замеряет задержку и держит самую быструю страну (кроме России)
  - name: ⚡ Самый быстрый
    type: url-test
    include-all: true
    exclude-filter: '(?i)Россия|БС'
    url: 'https://www.gstatic.com/generate_204'
    interval: 300
    tolerance: 50

  - name: 📺 Youtube
    type: select
    proxies:
      - 🛡️ VPN
    include-all: true

  - name: 💬 Telegram
    type: select
    proxies:
      - ⚡ Самый быстрый
      - 🛡️ VPN
      - DIRECT
    include-all: true

# Раздельное туннелирование (что напрямую, что через VPN, что блокировать)
# делает Xray по правилам из вашего Xray JSON в Remnawave — как в Happ.
# Здесь: локальная сеть, Steam и игры напрямую, отдельные группы для YouTube и Telegram.
# Свои группы и правила: /etc/connecta/groups.yaml и /etc/connecta/rules.yaml
rule-providers:
  private-domains: {behavior: domain, type: http, format: mrs, interval: 2592000, path: ./ruleset/geosite-private.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/private.mrs'}
  private-ips: {behavior: ipcidr, type: http, format: mrs, interval: 2592000, path: ./ruleset/geoip-private.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geoip/release/mihomo/private.mrs'}
  youtube: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/youtube.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/youtube.mrs'}
  telegram: {behavior: domain, type: http, format: mrs, interval: 86400, path: ./ruleset/telegram.mrs, url: 'https://cdn.jsdelivr.net/gh/hydraponique/roscomvpn-geosite/release/mihomo/telegram.mrs'}
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
  # Российское ТВ и видео (Wink и др.) — напрямую: телеканалы работают только с российского IP
  - DOMAIN-SUFFIX,wink.ru,DIRECT
  - DOMAIN-SUFFIX,wink.am,DIRECT
  - DOMAIN-SUFFIX,zabava.tv,DIRECT
  - DOMAIN-SUFFIX,restream.ru,DIRECT
  - DOMAIN-SUFFIX,restream-media.net,DIRECT
  - DOMAIN-SUFFIX,ngenix.net,DIRECT
  - DOMAIN-SUFFIX,mediavitrina.ru,DIRECT
  - DOMAIN-SUFFIX,vitrina.tv,DIRECT
  - DOMAIN-SUFFIX,more.tv,DIRECT
  - DOMAIN-SUFFIX,rt.ru,DIRECT
  - DOMAIN-SUFFIX,nowdrm.co,DIRECT
  # Проверки интернета в телефонах и ноутбуках — напрямую, чтобы при сбое VPN
  # устройства не писали «Нет доступа к интернету» и не отключались от Wi-Fi
  - DOMAIN,connectivitycheck.gstatic.com,DIRECT
  - DOMAIN,connectivitycheck.android.com,DIRECT
  - DOMAIN,www.gstatic.com,DIRECT
  - DOMAIN,clients3.google.com,DIRECT
  - DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
  - DOMAIN-SUFFIX,msftncsi.com,DIRECT
  - DOMAIN,captive.apple.com,DIRECT
  - DOMAIN,detectportal.firefox.com,DIRECT
  # Steam и игры — без VPN (домены + игровые серверы Valve и Riot по IP)
  - RULE-SET,steam,DIRECT
  - RULE-SET,epicgames,DIRECT
  - RULE-SET,riot,DIRECT
  - RULE-SET,origin,DIRECT
  - RULE-SET,escapefromtarkov,DIRECT
  - RULE-SET,faceit,DIRECT
  # Игровые серверы Valve (Dota 2, CS2) — AS32590
  - IP-CIDR,45.121.184.0/22,DIRECT,no-resolve
  - IP-CIDR,103.10.124.0/23,DIRECT,no-resolve
  - IP-CIDR,103.28.54.0/23,DIRECT,no-resolve
  - IP-CIDR,146.66.152.0/21,DIRECT,no-resolve
  - IP-CIDR,155.133.224.0/19,DIRECT,no-resolve
  - IP-CIDR,162.254.192.0/21,DIRECT,no-resolve
  - IP-CIDR,185.25.180.0/22,DIRECT,no-resolve
  - IP-CIDR,192.69.96.0/22,DIRECT,no-resolve
  - IP-CIDR,205.196.6.0/24,DIRECT,no-resolve
  - IP-CIDR,208.64.200.0/22,DIRECT,no-resolve
  - IP-CIDR,208.78.164.0/22,DIRECT,no-resolve
  # Игровые серверы Riot (Valorant, LoL) — AS6507
  - IP-CIDR,43.229.64.0/22,DIRECT,no-resolve
  - IP-CIDR,45.7.36.0/22,DIRECT,no-resolve
  - IP-CIDR,45.250.208.0/22,DIRECT,no-resolve
  - IP-CIDR,103.219.128.0/22,DIRECT,no-resolve
  - IP-CIDR,103.240.224.0/22,DIRECT,no-resolve
  - IP-CIDR,104.160.128.0/19,DIRECT,no-resolve
  - IP-CIDR,138.0.12.0/22,DIRECT,no-resolve
  - IP-CIDR,151.106.246.0/23,DIRECT,no-resolve
  - IP-CIDR,151.106.248.0/22,DIRECT,no-resolve
  - IP-CIDR,151.106.252.0/23,DIRECT,no-resolve
  - IP-CIDR,151.106.254.0/24,DIRECT,no-resolve
  - IP-CIDR,162.249.72.0/21,DIRECT,no-resolve
  - IP-CIDR,185.40.64.0/22,DIRECT,no-resolve
  - IP-CIDR,192.64.168.0/21,DIRECT,no-resolve
  - IP-CIDR,192.207.0.0/24,DIRECT,no-resolve
  # Telegram — отдельная группа (по умолчанию самый быстрый сервер)
  - RULE-SET,telegram,💬 Telegram
  - IP-CIDR,91.108.56.0/22,💬 Telegram,no-resolve
  - IP-CIDR,91.108.4.0/22,💬 Telegram,no-resolve
  - IP-CIDR,91.108.8.0/22,💬 Telegram,no-resolve
  - IP-CIDR,91.108.16.0/22,💬 Telegram,no-resolve
  - IP-CIDR,91.108.12.0/22,💬 Telegram,no-resolve
  - IP-CIDR,149.154.160.0/20,💬 Telegram,no-resolve
  - IP-CIDR,91.105.192.0/23,💬 Telegram,no-resolve
  - IP-CIDR,91.108.20.0/22,💬 Telegram,no-resolve
  - IP-CIDR,185.76.151.0/24,💬 Telegram,no-resolve
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

# VLESS без TLS/Reality к публичному серверу новые версии Xray не запускают —
# такие хосты пропускаем, чтобы один хост не ломал весь конфиг
INSECURE_DEF='
  def addr: (.settings.vnext[0].address // .settings.address // "");
  def enc: (.settings.vnext[0].users[0].encryption // .settings.encryption // "none");
  def private_addr: test("^(10\\.|127\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|localhost$)");
  def insecure: .protocol == "vless"
    and ((.streamSettings.security // "none") | . == "none" or . == "")
    and (enc == "none")
    and ((addr | private_addr) | not);
'
SKIPPED=$(jq -r "$INSECURE_DEF"' (if type == "array" then . else [.] end)
  | [ .[] | (.remarks // "?") as $r | (.outbounds // [])[] | select(insecure) | "\($r) → \(addr)" ] | unique | .[]' "$TMP_DIR/raw" 2>/dev/null)
[ -n "$SKIPPED" ] && log "Внимание: пропущены хосты VLESS без шифрования (включите TLS/Reality в панели): $(echo "$SKIPPED" | tr '\n' ';')"

# Все балансеры в одном Xray: у каждого свой вход (порт) и свои теги
jq --argjson port "$BASE_PORT" --argjson mark "$MARK" "$INSECURE_DEF"'
  def pfx($p): if . == null then null else $p + . end;
  (if type == "array" then . else [.] end)
  | (.[0].routing.domainStrategy // "AsIs") as $ds
  | [ to_entries[] | .key as $i | .value as $c | "c\($i)-" as $p
    | [ ($c.outbounds // [])[] | select(insecure | not) ] as $ob
    | ($ob | map(.tag)) as $ok
    | {
      inbound: {tag: "in-\($i)", listen: "127.0.0.1", port: ($port + $i), protocol: "socks",
        settings: {auth: "noauth", udp: true},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}},
      outbounds: [ $ob[]
        | .tag |= pfx($p)
        | if .proxySettings.tag then .proxySettings.tag |= pfx($p) else . end
        | .streamSettings = ((.streamSettings // {}) | .sockopt = ((.sockopt // {}) + {mark: $mark}))
        | if .streamSettings.sockopt.dialerProxy then .streamSettings.sockopt.dialerProxy |= pfx($p) else . end ],
      balancers: [ ($c.routing.balancers // [])[]
        | if .fallbackTag and (.fallbackTag as $f | $ok | index([$f]) | not) then del(.fallbackTag) else . end
        | .tag |= pfx($p) | .selector |= map($p + .)
        | if .fallbackTag then .fallbackTag |= pfx($p) else . end ],
      rules: ([ ($c.routing.rules // [])[] | select(.inboundTag == null)
        | select(.outboundTag == null or (.outboundTag as $t | $ok | index([$t])))
        | .inboundTag = ["in-\($i)"]
        | if .outboundTag then .outboundTag |= pfx($p) else . end
        | if .balancerTag then .balancerTag |= pfx($p) else . end ]
        + [ {type: "field", inboundTag: ["in-\($i)"],
             outboundTag: ($ob[0].tag | if . == null then "direct" else $p + . end)} ]),
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
    | while read -r d; do
        case "$d" in
          *[!0-9./]*) echo "  - DOMAIN-SUFFIX,$d,DIRECT" ;;
          */*)        echo "  - IP-CIDR,$d,DIRECT,no-resolve" ;;
          *)          echo "  - IP-CIDR,$d/32,DIRECT,no-resolve" ;;
        esac
      done > "$TMP_DIR/direct.yaml"
fi
# Свои группы и правила (не перезаписываются): /etc/connecta/groups.yaml, /etc/connecta/rules.yaml
build_clash() {  # $1 = 1 — со своими группами и правилами, 0 — без них
  : > "$TMP_DIR/cgroups.yaml"; : > "$TMP_DIR/crules.yaml"
  if [ "$1" = 1 ]; then
    [ -f /etc/connecta/groups.yaml ] && cp /etc/connecta/groups.yaml "$TMP_DIR/cgroups.yaml"
    [ -f /etc/connecta/rules.yaml ] && cp /etc/connecta/rules.yaml "$TMP_DIR/crules.yaml"
  fi
  awk -v f="$TMP_DIR/proxies.yaml" -v g="$TMP_DIR/direct.yaml" \
      -v cg="$TMP_DIR/cgroups.yaml" -v cr="$TMP_DIR/crules.yaml" '
    /^#PROXIES#$/ { while ((getline l < f) > 0) print l; next }
    /^#CUSTOM_GROUPS#$/ { while ((getline l < cg) > 0) print l; next }
    { print }
    /^rules:$/ { while ((getline l < g) > 0) print l; while ((getline l < cr) > 0) print l }' \
    "$DIR/clash-template.yaml" > "$TMP_DIR/clash.yaml"
}
build_clash 1
if [ -s "$TMP_DIR/cgroups.yaml" ] || [ -s "$TMP_DIR/crules.yaml" ]; then
  if [ -x /opt/clash/bin/clash ] && ! /opt/clash/bin/clash -d /opt/clash -f "$TMP_DIR/clash.yaml" -t >"$TMP_DIR/clash-test.log" 2>&1; then
    log "Внимание: ошибка в /etc/connecta/groups.yaml или rules.yaml — применяю без них. Подробности: $TMP_DIR/clash-test.log"
    build_clash 0
  fi
fi

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

clean() {  # https://www.site.ru/page?x=1 -> site.ru ; 1.2.3.4:443 -> 1.2.3.4 ; 1.2.3.0/24 остаётся
  x=$(echo "$1" | tr 'A-Z' 'a-z' | sed -E 's#^[a-z]+://##')
  if echo "$x" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?(:[0-9]+)?$'; then
    echo "$x" | sed -E 's#:[0-9]+$##'
  else
    echo "$x" | sed -E 's#[/:?\#].*$##; s#^www\.##'
  fi
}
apply() { /usr/bin/xray-sub-update.sh >/dev/null 2>&1 && echo "Применено." || echo "Сохранено, применится при следующем обновлении подписки."; }

case "$1" in
  add)
    [ -n "$2" ] || { echo "Пример: connecta add sberbank.ru"; exit 1; }
    shift
    for a in "$@"; do
      d=$(clean "$a"); [ -n "$d" ] || continue
      if grep -qxF "$d" "$LIST"; then echo "Уже в списке: $d"; else echo "$d" >> "$LIST"; echo "Без VPN: $d"; fi
    done
    apply ;;
  del|rm)
    [ -n "$2" ] || { echo "Пример: connecta del sberbank.ru"; exit 1; }
    shift
    for a in "$@"; do
      d=$(clean "$a")
      if grep -qxF "$d" "$LIST"; then grep -vxF "$d" "$LIST" > "$LIST.tmp"; mv "$LIST.tmp" "$LIST"; echo "Снова через VPN: $d"; else echo "Нет в списке: $d"; fi
    done
    apply ;;
  list|ls)
    if [ -s "$LIST" ]; then echo "Без VPN:"; sed 's/^/  • /' "$LIST"; else echo "Список исключений пуст."; fi ;;
  update)
    /usr/bin/connecta-autoupdate.sh now ;;
  autoupdate)
    case "$2" in
      off) touch /etc/connecta/no-autoupdate; echo "Автообновление выключено." ;;
      on)  rm -f /etc/connecta/no-autoupdate; echo "Автообновление включено." ;;
      *)   echo "connecta autoupdate on | off" ;;
    esac ;;
  version)
    echo "Версия: $(cat /etc/xray-sub/version 2>/dev/null || echo неизвестна)"
    if [ -f /etc/connecta/no-autoupdate ]; then echo "Автообновление: выключено"; else echo "Автообновление: включено (каждую ночь)"; fi ;;
  *)
    echo "connecta add <сайт или IP> — сайт или адрес пойдёт без VPN"
    echo "connecta del <сайт>        — снова через VPN"
    echo "connecta list              — список исключений"
    echo "connecta update            — обновить скрипт с GitHub прямо сейчас"
    echo "connecta autoupdate on|off — включить/выключить автообновление"
    echo "connecta version           — версия и статус автообновления" ;;
esac
EOC
chmod +x /usr/bin/connecta

# ---------- 5c. Автообновление скрипта с GitHub ----------
cat > /usr/bin/connecta-autoupdate.sh <<'EOU'
#!/bin/sh
# Раз в сутки проверяет install.sh на GitHub. Если VERSION там больше установленной —
# ставит обновление, проверяет, что VPN работает, а если нет — откатывается назад.
DIR=/etc/xray-sub
URL=https://raw.githubusercontent.com/Connecta-VPS/ConnectaRouter/main/install.sh
TMP=/tmp/connecta-upd
log() { logger -t connecta-update "$*"; echo "$*"; }

[ -f /etc/connecta/no-autoupdate ] && [ "$1" != "now" ] && exit 0
. "$DIR/settings" || exit 1
# Разносим обновления роутеров по времени (до 30 минут), чтобы не все сразу
[ "$1" = "now" ] || sleep "$(awk 'BEGIN{srand(); print int(rand()*1800)}')"

mkdir -p "$TMP"
curl -fsSL --max-time 60 "$URL?t=$(date +%s)" -o "$TMP/install.sh" || { log "Не удалось скачать обновление"; exit 1; }
REMOTE=$(sed -n 's/^VERSION=\([0-9][0-9]*\).*/\1/p' "$TMP/install.sh" | head -1)
LOCAL=$(cat "$DIR/version" 2>/dev/null || echo 0)
SKIP=$(cat "$DIR/skip-version" 2>/dev/null || echo 0)
[ -n "$REMOTE" ] || { log "В скачанном файле нет VERSION, пропускаю"; exit 1; }
if [ "$REMOTE" -le "$LOCAL" ]; then
  [ "$1" = "now" ] && log "Уже установлена последняя версия ($LOCAL)"
  exit 0
fi
if [ "$REMOTE" = "$SKIP" ] && [ "$1" != "now" ]; then exit 0; fi
sh -n "$TMP/install.sh" || { log "Файл обновления $REMOTE повреждён, пропускаю"; exit 1; }

log "Обновляю: $LOCAL -> $REMOTE"
tar -czf "$TMP/backup.tgz" /etc/xray-sub /usr/bin/xray-sub-update.sh /usr/bin/connecta \
  /usr/bin/connecta-autoupdate.sh /etc/init.d/xray-sub /opt/clash/config.yaml /etc/crontabs/root 2>/dev/null

ok=0
if sh "$TMP/install.sh" "$SUB_URL" > "$TMP/install.log" 2>&1; then
  sleep 20
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:10808 https://www.gstatic.com/generate_204)
  if [ "$code" = 204 ] && { /etc/init.d/clash running 2>/dev/null || pidof clash >/dev/null || pidof mihomo >/dev/null; }; then
    ok=1
  fi
fi

if [ "$ok" = 1 ]; then
  rm -f "$DIR/skip-version"
  log "Обновлено до версии $REMOTE"
else
  log "Версия $REMOTE не прошла проверку — откатываю. Лог: $TMP/install.log"
  tar -xzf "$TMP/backup.tgz" -C /
  echo "$REMOTE" > "$DIR/skip-version"
  /etc/init.d/cron restart 2>/dev/null
  /etc/init.d/xray-sub restart 2>/dev/null
  /etc/init.d/clash restart 2>/dev/null
  exit 1
fi
EOU
chmod +x /usr/bin/connecta-autoupdate.sh

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

# ---------- 7. Расписание: подписка (по умолчанию каждые 6 часов) и обновление скрипта ----------
# Если расписание уже есть (в т.ч. изменённое пользователем) — не трогаем его
touch /etc/crontabs/root
grep -q 'xray-sub-update.sh' /etc/crontabs/root || \
  echo "0 */6 * * * /usr/bin/xray-sub-update.sh >/dev/null 2>&1" >> /etc/crontabs/root
# Проверка обновлений скрипта — каждую ночь в 4:xx
grep -q 'connecta-autoupdate' /etc/crontabs/root || \
  echo "$(awk 'BEGIN{srand(); print int(rand()*60)}') 4 * * * /usr/bin/connecta-autoupdate.sh >/dev/null 2>&1" >> /etc/crontabs/root
/etc/init.d/cron enable 2>/dev/null || true
/etc/init.d/cron restart 2>/dev/null || true

# ---------- 8. Первый запуск ----------
say "Загружаю подписку..."
set +e
/usr/bin/xray-sub-update.sh || die "Подписка не загрузилась. Проверьте ссылку и запустите /usr/bin/xray-sub-update.sh ещё раз."
echo "$VERSION" > "$DIR/version"
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
say "Версия $VERSION, автообновление включено (connecta version)"
