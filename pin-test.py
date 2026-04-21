#!/usr/bin/env python3
# Diagnostic: blinks GPIO 13 (Pirate Audio backlight) and GPIO 9 (DC)
# at ~1.25 Hz for 8 ticks. Run with alphasound-display stopped.
#
#   rc-service alphasound-display stop
#   python3 /tmp/pin-test.py
#
# Watch the backlight. If it blinks -> GPIO 13 is ours. If it stays
# solid -> pin writes are being ignored (pinctrl conflict).

import time
import gpiod
from gpiod.line import Direction, Value

r = gpiod.request_lines(
    "/dev/gpiochip0",
    consumer="pin-test",
    config={
        9:  gpiod.LineSettings(direction=Direction.OUTPUT),
        13: gpiod.LineSettings(direction=Direction.OUTPUT),
    },
)
print("request OK")

for i in range(8):
    v = Value.ACTIVE if i % 2 == 0 else Value.INACTIVE
    r.set_value(9, v)
    r.set_value(13, v)
    print(f"tick {i} -> {v.name}")
    time.sleep(0.4)

r.release()
print("done")
