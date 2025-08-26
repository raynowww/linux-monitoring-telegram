FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl procps coreutils ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY monitor.sh /app/monitor.sh
RUN chmod +x /app/monitor.sh
# опционально: пример шаблона
COPY .env.example /app/.env.example

# Значения по умолчанию (можно переопределить)
ENV PROC_ROOT=/proc \
    DISK_PATH=/ \
    TAG=linux-monitor

ENTRYPOINT ["/usr/bin/env", "bash", "/app/monitor.sh"]