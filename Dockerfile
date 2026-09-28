# Hermuse di Koyeb: satu container berisi 9Router + Hermes gateway.
#
# Base image resmi Hermes Agent (Debian 13, Node + Python sudah ada, state di
# /opt/data). Kita hanya menambahkan 9Router dan skrip start yang menjalankan
# keduanya, karena Koyeb memberi satu container per service.
FROM nousresearch/hermes-agent:v2026.9.21

USER root

# 9Router (versi dipin; -g memasang ke prefix global image).
ARG NINEROUTER_VERSION=0.5.81
RUN npm install -g "9router@${NINEROUTER_VERSION}" \
    && npm cache clean --force

COPY docker/hermuse-start.sh /opt/hermuse/hermuse-start.sh
RUN chmod 0755 /opt/hermuse/hermuse-start.sh

# main-wrapper.sh menjalankan CMD non-`hermes` apa adanya sebagai user hermes.
CMD [ "/opt/hermuse/hermuse-start.sh" ]
