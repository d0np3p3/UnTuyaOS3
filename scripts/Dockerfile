# UnTuyaOS3 runtime image. Built by install-requirements.sh as "untuyaos3":
#
#     docker build -t untuyaos3 scripts/
#
# The project itself is not copied in; UnTuyaOS3.sh bind-mounts it at /untuyaos3.
FROM python:3

# Wi-Fi side: iw for scan/associate, iproute2 for ip, dhclient for the AP's DHCP.
RUN apt-get update \
    && apt-get install -y --no-install-recommends iw iproute2 isc-dhcp-client \
    && rm -rf /var/lib/apt/lists/*

# Python requirements for ap-ota.py (sslpsk3 compiles against the OpenSSL
# headers and toolchain already present in the full python image).
RUN pip install --no-cache-dir pyopenssl pycryptodome py-datastruct ltchiptool sslpsk3
