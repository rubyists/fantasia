import os
import signal
import subprocess
import sys
import time


def ignore_term():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


mode, pid_file = sys.argv[1:]
ignore_term()

if mode == "grandchild":
    with open(pid_file, "a", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    while True:
        time.sleep(60)

if mode == "child":
    with open(pid_file, "a", encoding="utf-8") as handle:
        handle.write(f"{os.getpid()}\n")
    grandchild = subprocess.Popen([sys.executable, __file__, "grandchild", pid_file])
    while True:
        time.sleep(60)

session_pid = os.fork()
if session_pid:
    os.waitpid(session_pid, 0)
    sys.exit(0)

os.setsid()
with open(pid_file, "w", encoding="utf-8") as handle:
    handle.write(f"{os.getpid()}\n")
child = subprocess.Popen([sys.executable, __file__, "child", pid_file])
while True:
    time.sleep(60)
