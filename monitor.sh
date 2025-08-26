#!/usr/bin/env bash
set -euo pipefail

# Загружаем переменные из .env
if [ -f ".env" ]; then
  set -a
  source ".env"
  set +a
fi

# Проверка обязательных переменных
: "${TELEGRAM_TOKEN:?TELEGRAM_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

# Значения по умолчанию
CPU_MAX="${CPU_MAX:-85}"
MEM_MAX="${MEM_MAX:-85}"
DISK_MAX="${DISK_MAX:-85}"
CHECK_PROCESSES="${CHECK_PROCESSES:-}"
HOSTNAME_TXT="${HOSTNAME_OVERRIDE:-$(hostname)}"
TAG="${TAG:-monitor}"
LOG_FILE="${LOG_FILE:-}"

# Ключевое для Docker-режима:
PROC_ROOT="${PROC_ROOT:-/proc}"   # внутри контейнера можно смонтировать /proc хоста сюда
DISK_PATH="${DISK_PATH:-/}"       # и корень хоста, если нужно проверять именно его

send_telegram() {
  local text="$1"
  local url="https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage"
  curl -s -X POST "$url" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "parse_mode=HTML" \
    -d "text=${text}" >/dev/null
}

percent_cpu() {
  read -r _ u1 n1 s1 i1 w1 irq1 si1 st1 _ _ < "${PROC_ROOT}/stat"
  local idle1=$i1 total1=$((u1+n1+s1+i1+w1+irq1+si1+st1))
  sleep 1
  read -r _ u2 n2 s2 i2 w2 irq2 si2 st2 _ _ < "${PROC_ROOT}/stat"
  local idle2=$i2 total2=$((u2+n2+s2+i2+w2+irq2+si2+st2))
  local idled=$((idle2-idle1)) totald=$((total2-total1))
  awk -v idled="$idled" -v totald="$totald" 'BEGIN {printf "%.0f", (100-100*idled/totald)}'
}

percent_mem() {
  awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {printf "%.0f", (1- a/t)*100}' "${PROC_ROOT}/meminfo"
}

percent_disk() {
  df -P "$DISK_PATH" | awk 'NR==2{gsub("%","",$5);print $5}'
}

check_processes() {
  local failed=()
  IFS=',' read -ra procs <<< "${CHECK_PROCESSES}"
  for p in "${procs[@]}"; do
    p=$(echo "$p" | xargs)
    [ -z "$p" ] && continue
    if ! pgrep -x "$p" >/dev/null 2>&1; then
      failed+=("$p")
    fi
  done
  echo "${failed[@]:-}"
}

main() {
  cpu=$(percent_cpu)
  mem=$(percent_mem)
  disk=$(percent_disk)
  failed_procs=$(check_processes || true)

  alerts=()
  [ "$cpu"  -ge "$CPU_MAX" ] && alerts+=("CPU ${cpu}%")
  [ "$mem"  -ge "$MEM_MAX" ] && alerts+=("RAM ${mem}%")
  [ "$disk" -ge "$DISK_MAX" ] && alerts+=("Disk ${disk}%")
  [ -n "${failed_procs:-}" ] && alerts+=("Down: ${failed_procs}")

  status="OK"
  [ "${#alerts[@]}" -gt 0 ] && status="ALERT"

  # Стилизация сообщения-алерта от бота в TG
  msg="<b>[${status}]</b> <b>${HOSTNAME_TXT}</b> — ${TAG}
<b>CPU:</b> ${cpu}% (max ${CPU_MAX}%)
<b>RAM:</b> ${mem}% (max ${MEM_MAX}%)
<b>Disk ${DISK_PATH}:</b> ${disk}% (max ${DISK_MAX}%)"
  if [ "${#alerts[@]}" -gt 0 ]; then
    msg+="

<b>Alerts:</b> $(IFS='; '; echo "${alerts[*]}")"
  else
    msg+="

<b>Alerts:</b> none"
  fi

  # Лог
  if [ -n "$LOG_FILE" ]; then
    printf "%s cpu=%s mem=%s disk=%s procs_down=%s status=%s\n" \
      "$(date -Is)" "$cpu" "$mem" "$disk" "${failed_procs:-none}" "$status" >> "$LOG_FILE"
  fi

  # Отправка
  if [ "${SEND_ALWAYS:-1}" -eq 1 ] || [ "$status" = "ALERT" ]; then
    send_telegram "$msg"
  fi
}

main "$@"