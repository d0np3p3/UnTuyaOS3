# syntax=docker/dockerfile:1
#
# UnTuyaOS3 container image. See the "Docker" section of README.md for how to
# give the container a Wi-Fi adapter.

ARG PYTHON_VERSION=3.13

# --- Build stage: compile the Python dependencies into a venv ---------------
# sslpsk3 is only published as an sdist (a C extension linked against
# OpenSSL), so it needs a toolchain and the OpenSSL headers to build.
FROM python:${PYTHON_VERSION}-slim-trixie AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libssl-dev \
 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# --- Runtime stage -----------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim-trixie
# iw: scan/associate, iproute2: ip, udhcpc: one-shot DHCP, rfkill: unblock radio,
# tini: PID 1, so Ctrl-C / docker stop reach the scripts (bash as PID 1 ignores
# SIGINT and SIGTERM)
RUN apt-get update \
 && apt-get install -y --no-install-recommends iw iproute2 udhcpc rfkill tini \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /opt/venv /opt/venv

# The venv comes first on PATH, so UnTuyaOS3.sh's `command -v python3` picks it
# up; the install step is skipped because the image already provides it all.
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UNTUYAOS3_SKIP_INSTALL=1

WORKDIR /app
COPY UnTuyaOS3.sh ./
COPY scripts/ scripts/
COPY custom-firmware/ custom-firmware/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
