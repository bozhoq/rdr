"""Summarize an iPhone recording and optionally export motion intervals."""

import argparse
import csv
import json
from contextlib import nullcontext
from pathlib import Path


def inspect(log_path, csv_path):
    if csv_path and csv_path.resolve() == log_path.resolve():
        raise ValueError("Выберите для CSV путь, отличный от пути лога.")

    counts = dict.fromkeys(("motion", "background_motion", "location", "sample_gaps", "receipt_gaps"), 0)
    start = previous = summary = None
    background = False
    max_sample_gap = max_receipt_gap = 0
    output = csv_path.open("w", newline="", encoding="utf-8") if csv_path else nullcontext()
    with output as csv_file, log_path.open(encoding="utf-8") as log:
        writer = csv.writer(csv_file) if csv_file else None
        if writer:
            writer.writerow(["seconds_since_start", "sample_interval_ms", "receipt_interval_ms", "background"])

        for line_number, line in enumerate(log, 1):
            # A process killed during a write can leave its last row incomplete.
            if not line.endswith("\n"):
                print(f"Незавершённая строка {line_number} пропущена.")
                break
            entry = json.loads(line)
            kind, received, data = entry["type"], entry["receivedAt"], entry["data"]
            if kind == "start":
                start = data["session"]
            elif kind == "end":
                summary = data
            elif kind == "event":
                if data["name"] in ("background", "active"):
                    background = data["name"] == "background"
                    print(f'{(received - start["startedAt"]) / 1000:.1f} с — {data["name"]}')
            elif kind == "location":
                counts["location"] += 1
            elif kind == "motion":
                if start is None:
                    raise ValueError("В логе нет начальной записи сессии.")
                motion_time = data["elapsedSinceFirstSampleSeconds"]
                counts["motion"] += 1
                counts["background_motion"] += int(background)
                if previous is not None:
                    sample_ms = (motion_time - previous[0]) * 1000
                    receipt_ms = received - previous[1]
                    max_sample_gap = max(max_sample_gap, sample_ms)
                    max_receipt_gap = max(max_receipt_gap, receipt_ms)
                    counts["sample_gaps"] += int(sample_ms > 100)
                    counts["receipt_gaps"] += int(receipt_ms > 100)
                    if writer:
                        writer.writerow([
                            f'{(received - start["startedAt"]) / 1000:.3f}',
                            f"{sample_ms:.3f}",
                            f"{receipt_ms:.3f}",
                            int(background),
                        ])
                previous = (motion_time, received)

    if start is None:
        raise ValueError("В логе нет начальной записи сессии.")
    print(f'Движение — {counts["motion"]} измерений, из них в фоне — {counts["background_motion"]}.')
    print(f'GPS — {counts["location"]} точек.')
    print(f'Интервалы датчика > 100 мс — {counts["sample_gaps"]}, максимум {max_sample_gap:.1f} мс.')
    print(f'Интервалы получения > 100 мс — {counts["receipt_gaps"]}, максимум {max_receipt_gap:.1f} мс.')
    if summary is None:
        print("Сессия без итоговой записи.")
    else:
        initial = start.get("batteryAtStartPercent")
        final = summary.get("batteryAtCheckpointPercent")
        if initial is not None and final is not None:
            print(f"Заряд — {initial}% → {final}%.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--csv", type=Path)
    args = parser.parse_args()
    try:
        inspect(args.log, args.csv)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"Ошибка чтения лога: {error}\n")


if __name__ == "__main__":
    main()
