"""Query a running Hush (started with HUSH_IPC=<socket>) via mpv JSON IPC.
Usage: python3 tools/ipc.py /tmp/hush-test.sock '[["get_property","speed"]]'"""
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile('rwb')
for i, cmd in enumerate(json.loads(sys.argv[2])):
    f.write((json.dumps({"command": cmd, "request_id": i}) + "\n").encode()); f.flush()
    while True:
        r = json.loads(f.readline())
        if r.get("request_id") == i:
            print(cmd[1] if cmd[0] == "get_property" else cmd, "=>", r.get("data", r.get("error"))); break
