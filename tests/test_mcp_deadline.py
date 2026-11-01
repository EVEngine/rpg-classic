"""Real loopback I/O: bounded preview RPCs cannot inherit an unbounded wait."""
import os
from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from rpgc import McpClient


class McpDeadlineTests(unittest.TestCase):
    def test_trickling_peer_and_env_override_cannot_extend_budget(self):
        stop = threading.Event()
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); listener.listen(1)
            def peer():
                conn, _ = listener.accept()
                with conn:
                    try:
                        while not stop.wait(.02):
                            conn.sendall(b' ')
                    except OSError:
                        pass
            worker = threading.Thread(target=peer, daemon=True); worker.start()
            start = time.monotonic()
            client = None
            try:
                with patch.dict(os.environ, {'EVE_RPC_TIMEOUT': '9999'}):
                    client = McpClient('127.0.0.1', listener.getsockname()[1], deadline=start+.18)
                    with self.assertRaises(TimeoutError):
                        client.initialize()
                self.assertLess(time.monotonic()-start, 1.0)
            finally:
                if client: client.close()
                stop.set(); worker.join(timeout=1)

    def test_expired_connection_budget_fails_immediately(self):
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            McpClient('127.0.0.1', 1, deadline=start-1)
        self.assertLess(time.monotonic()-start, .5)
