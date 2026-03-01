#!/usr/bin/env python3
import sys
import random

def main():
    if len(sys.argv) != 5:
        print(f"Usage: {sys.argv[0]} <file> <N> <min_len> <max_len>")
        sys.exit(1)

    filepath = sys.argv[1]

    try:
        N = int(sys.argv[2])
        min_len = int(sys.argv[3])
        max_len = int(sys.argv[4])
    except ValueError:
        print("Error: N, min_len, and max_len must all be integers.")
        sys.exit(1)

    if min_len > max_len:
        print("Error: min_len must be less than or equal to max_len.")
        sys.exit(1)

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            # strip newline and filter by length
            lines = [line.rstrip("\n") for line in f if min_len <= len(line.strip()) <= max_len]
    except FileNotFoundError:
        print(f"Error: File '{filepath}' not found.")
        sys.exit(1)

    if not lines:
        print(f"No lines found between lengths {min_len} and {max_len}.")
        sys.exit(0)

    N = min(N, len(lines))
    chosen = random.sample(lines, N)

    for line in chosen:
        print(line)

if __name__ == "__main__":
    main()
