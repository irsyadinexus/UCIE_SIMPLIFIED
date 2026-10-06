import subprocess
import sys
import time
import threading

def run_command_with_timer(cmd, expected_minutes, label):
    total_seconds = int(expected_minutes * 60)
    print(f"\n========================================================")
    print(f"SIMULATION STARTING: {label}")
    print(f"Expected runtime: {expected_minutes:.1f} minutes ({total_seconds} seconds)")
    print(f"========================================================\n", flush=True)

    start_time = time.time()

    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
    )

    output_lines = []

    def reader():
        for line in iter(proc.stdout.readline, ''):
            output_lines.append(line)
            if any(k in line for k in ["PASS", "FAIL", "==", "COMPILE", "LINK ACTIVE", "ERROR", "WARN", "COVERAGE"]):
                sys.stdout.write(f"  [SIM] {line}")
                sys.stdout.flush()
        proc.stdout.close()

    t = threading.Thread(target=reader)
    t.daemon = True
    t.start()

    last_report = 0
    while proc.poll() is None:
        time.sleep(1)
        elapsed = time.time() - start_time
        remaining = max(0, total_seconds - int(elapsed))
        curr_report = int(elapsed) // 10
        if curr_report != last_report:
            last_report = curr_report
            rem_m = remaining // 60
            rem_s = remaining % 60
            el_m = int(elapsed) // 60
            el_s = int(elapsed) % 60
            sys.stdout.write(f"\r[Countdown: {rem_m:02d}:{rem_s:02d} remaining | Elapsed: {el_m:02d}:{el_s:02d}]   ")
            sys.stdout.flush()

    t.join()
    proc.wait()
    elapsed = time.time() - start_time
    el_m = int(elapsed) // 60
    el_s = int(elapsed) % 60
    print(f"\n\n========================================================")
    print(f"SIMULATION COMPLETE: {label}")
    print(f"Total elapsed time: {el_m:02d}:{el_s:02d} (Exit code: {proc.returncode})")
    print(f"========================================================\n", flush=True)

    if proc.returncode != 0:
        print("--- Output from failed run ---")
        for line in output_lines[-50:]:
            sys.stdout.write(line)
        sys.stdout.flush()
        sys.exit(proc.returncode)
    else:
        for line in output_lines:
            if any(k in line for k in ["TEST PASSED", "ALL UNIT TESTS PASSED", "COVERAGE:", "LOOPBACK OK", "COMPILE OK", "PASSED", "coverage", "Merged", "100"]):
                print(f"  {line.strip()}")
        sys.stdout.flush()

if __name__ == "__main__":
    expected_min = float(sys.argv[1])
    target = sys.argv[2]
    cmd = ["wsl", "-d", "Ubuntu-24.04", "bash", "-c", f"cd /mnt/c/Users/User/Documents/RTL/UCIE_SIMPLIFIED/sim && make {target}"]
    run_command_with_timer(cmd, expected_min, f"make {target}")
