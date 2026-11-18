#!/usr/bin/env python3
"""Review/trust only installed Notch Ping hook hashes via the existing Codex daemon.

Does not start/restart a daemon, attach a thread, send prompts, or bypass hook trust.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import socket
import stat
import base64
import hashlib
import struct
import subprocess
import time
import tomllib

from hooks import command, entries, atomic_write, ensure_private_dir


class Client:
    def __init__(self):
        status = json.loads(subprocess.check_output(["codex", "app-server", "daemon", "version"]))
        if status.get("status") != "running":
            raise RuntimeError("The Codex daemon is not running; this setup never starts it")
        sock_path = status["socketPath"]
        link_stat = os.lstat(sock_path)
        sock_stat = os.stat(sock_path)
        if (link_stat.st_uid != os.getuid()
                or sock_stat.st_uid != os.getuid()
                or not stat.S_ISSOCK(sock_stat.st_mode)):
            raise RuntimeError("Refusing to connect to untrusted Codex daemon socket: " + str(sock_path))
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(10)
        self.socket.connect(sock_path)
        self.buffer = b""
        self.serial = 0
        key = base64.b64encode(os.urandom(16)).decode()
        self.socket.sendall(("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                             "Connection: Upgrade\r\nSec-WebSocket-Key: " + key +
                             "\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        while b"\r\n\r\n" not in self.buffer:
            self.buffer += self.socket.recv(4096)
            if len(self.buffer) > 16384:
                raise RuntimeError("Invalid WebSocket handshake")
        headers, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        if b" 101 " not in headers.split(b"\r\n",1)[0] or accept.lower() not in headers.lower():
            raise RuntimeError("Codex rejected the local WebSocket handshake")
        self.call("initialize", {"clientInfo": {"name": "notch_ping_setup", "version": "0.2.0"},
                                 "capabilities": {"experimentalApi": True}})
        self.send({"method": "initialized", "params": {}})

    def frame(self, payload, opcode=1):
        mask = os.urandom(4)
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", length)
        self.socket.sendall(header + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)))

    def send(self, message):
        self.frame(json.dumps(message).encode())

    def take(self, count):
        while len(self.buffer) < count:
            chunk = self.socket.recv(max(4096, count - len(self.buffer)))
            if not chunk:
                raise RuntimeError("Codex socket disconnected")
            self.buffer += chunk
        result, self.buffer = self.buffer[:count], self.buffer[count:]
        return result

    def message(self):
        fragments = b""
        while True:
            first, second = self.take(2)
            length = second & 127
            if length == 126:
                length = struct.unpack("!H", self.take(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.take(8))[0]
            if length > 8_388_608:
                raise RuntimeError("Unexpectedly large Codex setup response")
            mask = self.take(4) if second & 128 else None
            payload = self.take(length)
            if mask:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            opcode = first & 15
            if opcode == 8:
                raise RuntimeError("Codex closed the setup connection")
            if opcode == 9:
                self.frame(payload, 10)
                continue
            if opcode in (0, 1):
                fragments += payload
                if first & 128:
                    return json.loads(fragments)

    def call(self, method, params):
        self.serial += 1
        request_id = self.serial
        self.send({"id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            response = self.message()
            if response.get("id") == request_id:
                if "error" in response:
                    raise RuntimeError(str(response["error"]))
                return response["result"]
        raise RuntimeError("Timed out talking to the existing Codex daemon")

    def close(self):
        self.socket.close()


def valid_runtime_settings(hook):
    # Codex normalizes SessionEnd to synchronous even when configured async.
    expected_async = hook["eventName"] != "sessionEnd"
    return (hook.get("async") is expected_async
            and hook["timeoutSec"] == 1 and not hook["isManaged"])


def main(trust):
    home = Path.home()
    support = home / "Library/Application Support/NotchPing"
    helper = support / "bin/notch-relay"
    hook_file = home / ".codex/hooks.json"
    expected_command = command(helper, "codex")
    expected_events = {name[0].lower() + name[1:] for name, _ in entries("codex")}
    client = Client()
    try:
        def read_hooks():
            result = client.call("hooks/list", {"cwds": [str(Path(__file__).resolve().parents[1])]})
            found = []
            for group in result["data"]:
                if group["errors"]:
                    raise RuntimeError("Codex reported hook configuration errors: " + str(group["errors"]))
                for hook in group["hooks"]:
                    if hook.get("sourcePath") == str(hook_file) and hook.get("command") == expected_command:
                        found.append(hook)
            return found

        found = read_hooks()
        if {h["eventName"] for h in found} != expected_events or len(found) != len(expected_events):
            raise RuntimeError("The installed Notch Ping hooks do not match the reviewed event set")
        for hook in found:
            if not valid_runtime_settings(hook):
                raise RuntimeError("Unexpected hook settings; refusing trust update")
            print(hook["eventName"] + ": " + hook["trustStatus"])
        if not trust:
            return
        config_path = home / ".codex/config.toml"
        if config_path.is_symlink() or config_path.parent.is_symlink():
            raise RuntimeError("Refusing to modify symlinked Codex configuration")
        before = config_path.read_bytes()
        original = tomllib.loads(before.decode())
        config = client.call("config/read", {"includeLayers": True})
        layer = next(item for item in config["layers"]
                     if item["name"].get("type") == "user" and item["name"].get("file") == str(config_path))
        if config_path.read_bytes() != before:
            raise RuntimeError("Codex settings changed during review; retry")
        ensure_private_dir(support, 0o700)
        ensure_private_dir(support / "backups", 0o700)
        backup_dir = support / "backups" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
        ensure_private_dir(backup_dir, 0o700)
        backup = backup_dir / "codex-config.toml"
        atomic_write(backup, before, 0o600)
        edits = [{"keyPath": "hooks.state." + json.dumps(h["key"]) + ".trusted_hash",
                  "value": h["currentHash"], "mergeStrategy": "replace"} for h in found]
        client.call("config/batchWrite", {"edits": edits, "filePath": str(config_path),
                                           "expectedVersion": layer["version"], "reloadUserConfig": True})
        updated = tomllib.loads(config_path.read_text())
        # Exact trust keys are the only intended changes; preserve all other settings.
        for hook in found:
            updated.get("hooks", {}).get("state", {}).pop(hook["key"], None)
            original.get("hooks", {}).get("state", {}).pop(hook["key"], None)
        if updated != original:
            raise RuntimeError("Unexpected additional config change; backup: " + str(backup))
        verified = read_hooks()
        if not all(h["trustStatus"] == "trusted" and h["enabled"] for h in verified):
            raise RuntimeError("Codex has not activated every hook")
        print("Verified: all " + str(len(verified)) + " Notch Ping hooks trusted and enabled. Existing notification settings preserved.")
        print("Config backup: " + str(backup))
    finally:
        client.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trust", action="store_true", help="Trust only the exact reviewed Notch Ping hook hashes")
    args = parser.parse_args()
    main(args.trust)
