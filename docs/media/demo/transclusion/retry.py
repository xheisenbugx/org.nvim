import time


def retry(fn, attempts=3, delay=0.5):
    """Call fn until it succeeds or attempts run out."""
    for n in range(attempts):
        try:
            return fn()
        except OSError:
            time.sleep(delay * 2**n)
    raise RuntimeError("gave up")


if __name__ == "__main__":
    print(retry(lambda: "ok"))
