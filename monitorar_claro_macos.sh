#!/bin/bash
# Monitor de conexão Claro residencial em macOS — sem dependências externas.
# Uso: ./monitorar_claro_macos.sh [opções]

set -u
set -o pipefail

DURATION_MIN=120
INTERVAL_MIN=5
GATEWAY=""
PING_COUNT=10
NQ_EVERY=4                 # 4 ciclos x 5 min = aproximadamente 20 min
OUTPUT_DIR=""
KEEP_NQ_RAW=1

usage() {
  cat <<'EOF'
Uso: monitorar_claro_macos.sh [opções]

  -d, --duration MIN           Duração total (padrão: 120)
  -i, --interval MIN           Intervalo entre ciclos (padrão: 5)
  -g, --gateway IPV4           Gateway a testar (padrão: detectado automaticamente)
  -p, --ping-count N           Pings por destino em cada ciclo (padrão: 10)
  -n, --network-quality-every N
                               Executa networkQuality a cada N ciclos (padrão: 4;
                               use 1 para todos os ciclos e 0 para desativar)
  -o, --output-dir DIRETÓRIO   Diretório dos resultados (padrão: claro-monitor-AAA...)
  -h, --help                   Mostra esta ajuda

Exemplo (2 h, a cada 5 min):
  ./monitorar_claro_macos.sh

Interrompa com Ctrl-C; o resumo parcial ainda será gerado.
EOF
}

require_value() {
  [ $# -ge 2 ] || { echo "Falta valor para $1." >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--duration) require_value "$@"; DURATION_MIN="$2"; shift 2 ;;
    -i|--interval) require_value "$@"; INTERVAL_MIN="$2"; shift 2 ;;
    -g|--gateway) require_value "$@"; GATEWAY="$2"; shift 2 ;;
    -p|--ping-count) require_value "$@"; PING_COUNT="$2"; shift 2 ;;
    -n|--network-quality-every) require_value "$@"; NQ_EVERY="$2"; shift 2 ;;
    -o|--output-dir) require_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opção desconhecida: $1" >&2; usage >&2; exit 2 ;;
  esac
done

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
for value in "$DURATION_MIN" "$INTERVAL_MIN" "$PING_COUNT" "$NQ_EVERY"; do
  is_uint "$value" || { echo "Os valores de duração, intervalo, pings e networkQuality devem ser inteiros." >&2; exit 2; }
done
[ "$DURATION_MIN" -gt 0 ] && [ "$INTERVAL_MIN" -gt 0 ] && [ "$PING_COUNT" -gt 0 ] || { echo "Duração, intervalo e pings devem ser maiores que zero." >&2; exit 2; }

# Em uma ligação direta ao modem, o gateway padrão do macOS é o primeiro salto.
# A detecção evita embutir endereço algum da instalação no repositório.
if [ -z "$GATEWAY" ]; then
  GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
fi
[ -n "$GATEWAY" ] || { echo "Não foi possível detectar o gateway padrão. Informe-o com --gateway IPV4." >&2; exit 1; }

START_EPOCH=$(date +%s)
RUN_ID=$(date +%Y%m%d-%H%M%S)
OUTPUT_DIR=${OUTPUT_DIR:-"claro-monitor-${RUN_ID}"}
mkdir -p "$OUTPUT_DIR/networkquality" || exit 1
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

MEASUREMENTS="$OUTPUT_DIR/medicoes.csv"
DNS_CSV="$OUTPUT_DIR/dns.csv"
HTTP_CSV="$OUTPUT_DIR/https.csv"
NQ_CSV="$OUTPUT_DIR/networkquality.csv"
EVENTS="$OUTPUT_DIR/eventos.log"
SUMMARY="$OUTPUT_DIR/resumo.txt"

csv() { # Escapa aspas para CSV e mantém o separador consistente.
  local first=1 item escaped
  for item in "$@"; do
    escaped=${item//\"/\"\"}
    [ $first -eq 1 ] || printf ','
    printf '"%s"' "$escaped"
    first=0
  done
  printf '\n'
}

event() {
  local level="$1"; shift
  local msg="$*"
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$msg" | tee -a "$EVENTS"
}

printf 'timestamp,cycle,target,transmitted,received,loss_pct,min_ms,avg_ms,max_ms,jitter_ms,status\n' > "$MEASUREMENTS"
printf 'timestamp,cycle,resolver,record_type,answer,latency_ms,status,detail\n' > "$DNS_CSV"
printf 'timestamp,cycle,ip_family,url,http_code,connect_s,ttfb_s,total_s,remote_ip,status,detail\n' > "$HTTP_CSV"
printf 'timestamp,cycle,status,upload_mbps,download_mbps,responsiveness_rpm,base_rtt_ms,raw_file\n' > "$NQ_CSV"

command -v ping >/dev/null || { echo "O comando ping não foi encontrado." >&2; exit 1; }
HAS_DIG=0; command -v dig >/dev/null && HAS_DIG=1
HAS_CURL=0; command -v curl >/dev/null && HAS_CURL=1
HAS_NQ=0; command -v networkQuality >/dev/null && HAS_NQ=1

if [ "$HAS_NQ" -eq 0 ]; then event INFO 'networkQuality não está disponível neste macOS; os demais testes continuarão.'; fi
if [ "$HAS_DIG" -eq 0 ]; then event WARN 'dig não está disponível; o teste DNS será marcado como indisponível.'; fi
if [ "$HAS_CURL" -eq 0 ]; then event WARN 'curl não está disponível; os testes HTTPS serão marcados como indisponíveis.'; fi

ping_target() {
  local timestamp="$1" cycle="$2" target="$3" label="$4" output tx rx loss min avg max jitter status
  # -W é o timeout por resposta em milissegundos no ping do macOS.
  output=$(ping -n -c "$PING_COUNT" -W 1000 "$target" 2>&1 || true)
  tx=$(awk '/packets transmitted/ {print $1; exit}' <<<"$output")
  rx=$(awk '/packets transmitted/ {print $4; exit}' <<<"$output")
  loss=$(awk -F', ' '/packet loss/ {for(i=1;i<=NF;i++) if($i ~ /packet loss/) {gsub(/% packet loss/,"",$i); print $i; exit}}' <<<"$output")
  read -r min avg max jitter < <(awk -F'[ =/]+' '/min\/avg\/max/ {print $(NF-4),$(NF-3),$(NF-2),$(NF-1); exit}' <<<"$output")
  tx=${tx:-0}; rx=${rx:-0}; loss=${loss:-100}; min=${min:-}; avg=${avg:-}; max=${max:-}; jitter=${jitter:-}
  status=ok
  if ! is_number "$loss" || awk "BEGIN {exit !($loss > 0)}"; then status=degraded; fi
  if [ "$label" = gateway ] && { { is_number "$avg" && awk "BEGIN {exit !($avg > 50)}"; } || { is_number "$jitter" && awk "BEGIN {exit !($jitter > 20)}"; }; }; then status=degraded; fi
  if [ "$label" = internet ] && { { is_number "$avg" && awk "BEGIN {exit !($avg > 100)}"; } || { is_number "$jitter" && awk "BEGIN {exit !($jitter > 30)}"; }; }; then status=degraded; fi
  csv "$timestamp" "$cycle" "$target" "$tx" "$rx" "$loss" "$min" "$avg" "$max" "$jitter" "$status" >> "$MEASUREMENTS"
  if [ "$status" != ok ]; then event WARN "Ciclo $cycle: ping $target ($label): perda ${loss}%, média ${avg:-n/d} ms, jitter ${jitter:-n/d} ms."; fi
}

dns_test() {
  local timestamp="$1" cycle="$2" resolver="$3" server="$4" output answer elapsed status detail start end
  if [ "$HAS_DIG" -eq 0 ]; then csv "$timestamp" "$cycle" "$resolver" A '' '' unavailable 'dig ausente' >> "$DNS_CSV"; return; fi
  start=$(date +%s)
  if [ -n "$server" ]; then output=$(dig +time=4 +tries=1 +short A example.com "@$server" 2>&1); else output=$(dig +time=4 +tries=1 +short A example.com 2>&1); fi
  end=$(date +%s); elapsed=$(( (end - start) * 1000 ))
  answer=$(awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print; exit}' <<<"$output")
  status=ok; detail=''
  if [ -z "$answer" ]; then status=failed; detail=$(tr '\n' ' ' <<<"$output" | cut -c1-180); event WARN "Ciclo $cycle: DNS via $resolver falhou: $detail"; fi
  csv "$timestamp" "$cycle" "$resolver" A "$answer" "$elapsed" "$status" "$detail" >> "$DNS_CSV"
}

https_test() {
  local timestamp="$1" cycle="$2" family="$3" curl_flag="$4" url='https://www.cloudflare.com/cdn-cgi/trace' result code connect ttfb total remote status detail
  if [ "$HAS_CURL" -eq 0 ]; then csv "$timestamp" "$cycle" "$family" "$url" '' '' '' '' '' unavailable 'curl ausente' >> "$HTTP_CSV"; return; fi
  result=$(curl "$curl_flag" -sS -o /dev/null --connect-timeout 5 --max-time 15 -w '%{http_code}|%{time_connect}|%{time_starttransfer}|%{time_total}|%{remote_ip}' "$url" 2>&1)
  if [[ "$result" == *'|'* ]]; then
    IFS='|' read -r code connect ttfb total remote <<<"$result"
    status=ok; detail=''
    [[ "$code" =~ ^2[0-9][0-9]$ ]] || { status=failed; detail="HTTP $code"; }
  else
    code=''; connect=''; ttfb=''; total=''; remote=''; status=failed; detail=$(tr '\n' ' ' <<<"$result" | cut -c1-180)
  fi
  csv "$timestamp" "$cycle" "$family" "$url" "$code" "$connect" "$ttfb" "$total" "$remote" "$status" "$detail" >> "$HTTP_CSV"
  [ "$status" = ok ] || event WARN "Ciclo $cycle: HTTPS IPv$family falhou: ${detail:-HTTP $code}."
}

network_quality_test() {
  local timestamp="$1" cycle="$2" raw output up down rpm rtt status
  [ "$HAS_NQ" -eq 1 ] || return
  raw="$OUTPUT_DIR/networkquality/ciclo-$(printf '%03d' "$cycle").txt"
  output=$(networkQuality -v 2>&1 || true)
  printf '%s\n' "$output" > "$raw"
  up=$(awk -F': ' '/Upload capacity:/ {gsub(/ Mbps/,"",$2); print $2; exit}' <<<"$output")
  down=$(awk -F': ' '/Download capacity:/ {gsub(/ Mbps/,"",$2); print $2; exit}' <<<"$output")
  rpm=$(awk -F'[()]' '/Responsiveness:/ {gsub(/ RPM/,"",$2); print $2; exit}' <<<"$output")
  rtt=$(awk -F': ' '/Base RTT:/ {gsub(/ ms/,"",$2); print $2; exit}' <<<"$output")
  status=ok
  if ! is_number "${down:-}" || ! is_number "${up:-}"; then status=failed; event WARN "Ciclo $cycle: networkQuality não retornou capacidades; veja $raw."; fi
  csv "$timestamp" "$cycle" "$status" "$up" "$down" "$rpm" "$rtt" "$raw" >> "$NQ_CSV"
  [ "$KEEP_NQ_RAW" -eq 1 ] || rm -f "$raw"
}

write_summary() {
  local now elapsed cycles
  now=$(date +%s); elapsed=$((now - START_EPOCH)); cycles=$(awk 'END {print NR-1}' "$MEASUREMENTS")
  {
    echo "RESUMO — monitor Claro"
    echo "Gerado: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "Duração observada: $((elapsed / 60)) min $((elapsed % 60)) s"
    echo "Gateway configurado: $GATEWAY | Pings por destino/ciclo: $PING_COUNT"
    echo
    echo "Ping por destino (média das médias; perda total; pior média; maior jitter):"
    awk -F, 'NR>1 {gsub(/\"/,"",$0); t=$3; tx[t]+=$4; rx[t]+=$5; if($8!=""){sum[t]+=$8;n[t]++} if($8+0>maxavg[t])maxavg[t]=$8; if($10+0>maxjit[t])maxjit[t]=$10} END {for(t in tx) printf "  %-16s média=%7.2f ms | perda=%6.2f%% (%d/%d) | pior média=%7.2f ms | maior jitter=%7.2f ms\n",t,(n[t]?sum[t]/n[t]:0),100*(tx[t]-rx[t])/tx[t],tx[t]-rx[t],tx[t],maxavg[t],maxjit[t]}' "$MEASUREMENTS" | sort
    echo
    echo "Falhas: DNS=$(awk -F, 'NR>1 && $7 != "\"ok\"" {n++} END {print n+0}' "$DNS_CSV") | HTTPS=$(awk -F, 'NR>1 && $10 != "\"ok\"" {n++} END {print n+0}' "$HTTP_CSV") | eventos WARN=$(grep -c '\[WARN\]' "$EVENTS" 2>/dev/null || true)"
    echo
    echo "Leitura rápida:"
    echo "  • Problema no gateway junto com destinos externos sugere enlace modem/Claro/CMTS."
    echo "  • Gateway limpo, mas 1.1.1.1/8.8.8.8 ruins sugere problema além do primeiro salto."
    echo "  • IPs bons, porém DNS/HTTPS falhando, sugere resolução, rota ou aplicação — não perda ICMP simples."
    echo "  • HTTPS IPv4 bom e IPv6 falho isola o problema na conectividade IPv6."
    echo "  • Compare horários de WARN com capacidade/RTT do networkQuality; latência carregada alta costuma aparecer como responsividade menor."
    echo
    echo "Arquivos: medicoes.csv, dns.csv, https.csv, networkquality.csv, eventos.log e networkquality/."
  } > "$SUMMARY"
  cat "$SUMMARY"
}

on_exit() {
  event INFO 'Encerrando monitor e gerando resumo.'
  write_summary
}
trap on_exit EXIT
trap 'event INFO "Interrompido pelo usuário (Ctrl-C)."; exit 0' INT TERM

event INFO "Início: duração ${DURATION_MIN} min, intervalo ${INTERVAL_MIN} min, gateway $GATEWAY. Resultados: $OUTPUT_DIR"
echo "Monitorando. Resultados em: $OUTPUT_DIR"
echo "Use Ctrl-C para encerrar antes; o resumo será preservado."

DEADLINE=$((START_EPOCH + DURATION_MIN * 60))
CYCLE=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  CYCLE=$((CYCLE + 1))
  TS=$(date '+%Y-%m-%dT%H:%M:%S%z')
  event INFO "Ciclo $CYCLE iniciado."
  ping_target "$TS" "$CYCLE" "$GATEWAY" gateway
  ping_target "$TS" "$CYCLE" '1.1.1.1' internet
  ping_target "$TS" "$CYCLE" '8.8.8.8' internet
  dns_test "$TS" "$CYCLE" system ''
  dns_test "$TS" "$CYCLE" '1.1.1.1' '1.1.1.1'
  https_test "$TS" "$CYCLE" 4 -4
  https_test "$TS" "$CYCLE" 6 -6
  if [ "$NQ_EVERY" -gt 0 ] && [ $((CYCLE % NQ_EVERY)) -eq 0 ]; then network_quality_test "$TS" "$CYCLE"; fi
  event INFO "Ciclo $CYCLE concluído."
  NEXT=$((START_EPOCH + CYCLE * INTERVAL_MIN * 60))
  NOW=$(date +%s)
  [ "$NEXT" -gt "$DEADLINE" ] && NEXT=$DEADLINE
  [ "$NEXT" -gt "$NOW" ] && sleep $((NEXT - NOW))
done
