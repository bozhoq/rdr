"""Offline reference for ground-1; native app uses JumpDetector.swift.

This script reads logs locally, prints no coordinates, and never uploads data.
It also creates synthetic cross-language parity fixtures for CI when requested.
"""
import argparse
import json
import math
from pathlib import Path


class Detector:
    def __init__(self):
        self.previous = None
        self.discontinuities = 0
        self.clear()

    def clear(self):
        self.loaded_since = None
        self.armed = False
        self.flight = None
        self.landing = None

    def discontinuity(self):
        self.discontinuities += 1
        self.previous = None
        self.clear()

    def process(self, sample):
        t = sample['elapsedSinceFirstSampleSeconds']
        a, g, r = (sample[k] for k in ['accelerationG', 'gravityG', 'rotationRadiansPerSecond'])
        load = math.sqrt(sum((a[k] + g[k]) ** 2 for k in 'xyz'))
        spin = math.sqrt(sum(r[k] ** 2 for k in 'xyz'))
        if not all(map(math.isfinite, [t, load, spin])) or t < 0:
            self.discontinuity()
            return
        if self.previous is not None and (t <= self.previous or t - self.previous > .05):
            self.discontinuity()
        self.previous = t
        if self.landing is not None:
            event = self.landing
            if t - event['endSeconds'] <= .20:
                event['returnPeakG'] = max(event['returnPeakG'], load)
            if t - event['endSeconds'] >= .20:
                self.clear()
                if event['returnPeakG'] >= 1.5:
                    return event
            return
        if self.flight is not None:
            duration = t - self.flight['startSeconds']
            if duration > 3:
                self.clear()
                return
            if load < .65:
                self.flight['minimumLoadG'] = min(self.flight['minimumLoadG'], load)
                self.flight['maximumRotationRadiansPerSecond'] = max(self.flight['maximumRotationRadiansPerSecond'], spin)
            else:
                event = dict(self.flight, endSeconds=t, returnPeakG=load)
                self.clear()
                if duration >= .22:
                    self.landing = event
            return
        if load < .4:
            if self.armed:
                self.flight = dict(startSeconds=t, minimumLoadG=load, maximumRotationRadiansPerSecond=spin)
            self.armed = False
            self.loaded_since = None
        elif load >= .8:
            if self.loaded_since is None:
                self.loaded_since = t
            if t - self.loaded_since >= .20:
                self.armed = True
        elif not self.armed:
            self.loaded_since = None


def analyze(path):
    detector, events = Detector(), []
    with Path(path).open(encoding='utf-8-sig') as stream:
        for line in stream:
            if not line.strip():
                continue
            try:
                row = json.loads(line)
                if row['type'] == 'motion':
                    event = detector.process(row['data'])
                    if event:
                        events.append(event)
            except (ValueError, KeyError, TypeError):
                detector.discontinuity()
    return dict(detectorVersion='ground-1', candidates=events, discontinuities=detector.discontinuities)


def synthetic_cases():
    import random
    rng = random.Random(20261116)
    cases = []
    for case in range(80):
        samples = []
        detector, expected = Detector(), []
        t = 0
        for i in range(600):
            load = .08 + rng.random() * .12 if 100 <= i < 100 + case * 3 else 1
            if i == 100 + case * 3:
                load = 3
            theta = i * .07
            g = dict(x=math.sin(theta), y=0, z=-math.cos(theta))
            a = {k: (load - 1) * v for k, v in g.items()}
            t += .008 + rng.random() * .004
            if case % 5 == 0 and i == 120:
                t += .2
            sample = dict(elapsedSinceFirstSampleSeconds=t, accelerationG=a, gravityG=g,
                          rotationRadiansPerSecond=dict(x=0, y=7, z=0),
                          attitude=dict(x=0, y=0, z=0, w=1), verticalAccelerationMetersPerSecondSquared=0)
            samples.append(sample)
            event = detector.process(sample)
            if event:
                expected.append(event)
        cases.append(dict(samples=samples, expected=expected, discontinuities=detector.discontinuities))
    return cases


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', nargs='*')
    parser.add_argument('--output')
    parser.add_argument('--synthetic-fixtures')
    args = parser.parse_args()
    if args.synthetic_fixtures:
        Path(args.synthetic_fixtures).write_text(json.dumps(synthetic_cases(), separators=(',', ':')), encoding='utf-8')
    report = {Path(path).name: analyze(path) for path in args.files}
    if args.files:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    if args.output:
        Path(args.output).write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
