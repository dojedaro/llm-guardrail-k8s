#!/usr/bin/env python3
"""Send a steady stream of chat requests and count what comes back, to measure downtime during a rollout,
a node drain or any other disruption. Standard library only; one new TCP connection per request.

    python scripts/availability_probe.py --url http://127.0.0.1:8080 --host guardrail.localtest.me \
        --seconds 90 --rate 20
Exit code 0 always: it reports, the caller decides what is acceptable. Prints a summary with
status-code counts, transport errors (refused, reset, timeout) and the time of the first/last failure.
"""

from __future__ import annotations

import argparse
import collections
import json
import threading
import time
import urllib.error
import urllib.request


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument(
        "--url",
        required=True,
        help="use 127.0.0.1, not localhost: on Windows localhost tries IPv6 first (~2 s)",
    )
    ap.add_argument("--host", help="Host header (to go through an ingress rule)")
    ap.add_argument("--path", default="/v1/chat")
    ap.add_argument("--seconds", type=float, default=60)
    ap.add_argument("--rate", type=float, default=20, help="total requests per second, best effort")
    ap.add_argument("--workers", type=int, default=4, help="concurrent request loops")
    ap.add_argument("--timeout", type=float, default=5)
    args = ap.parse_args()

    body = json.dumps(
        {"messages": [{"role": "user", "content": "availability probe, mail me at probe@example.com"}]}
    ).encode()
    headers = {"content-type": "application/json"}
    if args.host:
        headers["Host"] = args.host
    counts: collections.Counter = collections.Counter()
    failures: list[tuple[float, str]] = []
    lock = threading.Lock()
    t_start = time.time()

    def loop() -> None:
        interval = args.workers / args.rate
        while time.time() - t_start < args.seconds:
            t0 = time.time()
            try:
                req = urllib.request.Request(args.url + args.path, data=body, headers=headers, method="POST")
                with urllib.request.urlopen(req, timeout=args.timeout) as r:
                    label = f"HTTP {r.status}"
            except urllib.error.HTTPError as e:
                label = f"HTTP {e.code}"
            except Exception as e:  # refused, reset, timeout
                label = f"transport error: {type(e).__name__}"
            with lock:
                counts[label] += 1
                if label != "HTTP 200":
                    failures.append((round(time.time() - t_start, 1), label))
            time.sleep(max(0, interval - (time.time() - t0)))

    threads = [threading.Thread(target=loop) for _ in range(args.workers)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    n = sum(counts.values())
    print(
        f"requests sent: {n} in {time.time() - t_start:.0f}s (target {args.rate:g}/s, {args.workers} concurrent loops)"
    )
    for k, v in sorted(counts.items()):
        print(f"  {k}: {v}")
    print(f"failed requests: {sum(v for k, v in counts.items() if k != 'HTTP 200')} of {n}")
    if failures:
        failures.sort()
        print(
            f"first failure at t+{failures[0][0]}s ({failures[0][1]}), last at t+{failures[-1][0]}s ({failures[-1][1]})"
        )


if __name__ == "__main__":
    main()
