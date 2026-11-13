# Stopwatch Peripheral – Register Map

SCOMP I/O addresses 0x70–0x7F are reserved for this peripheral. All registers are 16 bits.

## Summary

| Address | Name       | Access | Description                                      |
|---------|------------|--------|--------------------------------------------------|
| 0x70    | CTRL       | W/R    | Run/pause, reset, resolution select              |
| 0x71    | TIME       | R      | Current elapsed time                             |
| 0x72    | LAP        | W/R    | Write: record a lap · Read: pop oldest lap       |
| 0x73    | STATUS     | R      | Lap count, FIFO flags, overflow, running         |
| 0x74    | EVT_CTRL   | W/R    | Enable event capture, clear event FIFO           |
| 0x75    | EVT_READ   | R      | Pop oldest event timestamp                       |
| 0x76    | EVT_STATUS | R      | Event count, FIFO flags, enabled                 |
| 0x77–0x7F | —        | —      | Reserved for stretch features                    |

## Register Details

### 0x70 – CTRL (W/R)

| Bit(s) | Name   | Description                                                  |
|--------|--------|--------------------------------------------------------------|
| 0      | RUN    | 1 = run, 0 = pause                                           |
| 1      | RESET  | Write 1 to clear time, laps, and flags (not stored)          |
| 3:2    | —      | Unused (write 0)                                             |
| 5:4    | RES    | Resolution: 00 = 1 ms, 01 = 10 ms, 10 = 100 ms, 11 = 1 s     |
| 15:6   | —      | Unused (write 0)                                             |

Writes set RUN and RES together, so always write the full value (e.g. to pause at 10 ms resolution, write `0x0010`, not `0x0000`).

### 0x71 – TIME (R)

Current elapsed time in units of the selected resolution. Reading does not stop or reset the count. Wraps from 0xFFFF to 0x0000 and sets the overflow flag.

### 0x72 – LAP (W/R)

- **Write (any value):** stores the current time in the lap FIFO (holds 8 laps).
- **Read:** returns the oldest stored lap and removes it from the FIFO. Returns 0 if empty.
- If the FIFO is full, the new lap is dropped and the lap-lost flag is set.

### 0x73 – STATUS (R)

| Bit(s) | Name     | Description                                |
|--------|----------|--------------------------------------------|
| 3:0    | LAP_CNT  | Number of laps waiting in the FIFO (0–8)   |
| 4      | LAP_FULL | Lap FIFO is full                           |
| 5      | LAP_LOST | A lap was dropped because the FIFO was full|
| 6      | OVF      | Time wrapped past 0xFFFF                   |
| 7      | RUNNING  | Stopwatch is running                       |
| 15:8   | —        | Reads as 0                                 |

LAP_LOST and OVF stay set until a reset.

### 0x74 – EVT_CTRL (W/R)

| Bit(s) | Name   | Description                                         |
|--------|--------|-----------------------------------------------------|
| 0      | EN     | 1 = capture timestamps on the event input           |
| 1      | CLEAR  | Write 1 to empty the event FIFO and clear EVT_LOST  |
| 15:2   | —      | Unused (write 0)                                    |

The event input (e.g. a pushbutton) is debounced in hardware. Each clean press stores the current time in the event FIFO without any CPU involvement.

### 0x75 – EVT_READ (R)

Returns the oldest event timestamp and removes it from the event FIFO (holds 16). Returns 0 if empty.

### 0x76 – EVT_STATUS (R)

| Bit(s) | Name      | Description                                    |
|--------|-----------|------------------------------------------------|
| 4:0    | EVT_CNT   | Number of events waiting (0–16)                |
| 5      | EVT_FULL  | Event FIFO is full                             |
| 6      | EVT_LOST  | An event was dropped because the FIFO was full |
| 7      | EVT_EN    | Event capture is enabled                       |
| 15:8   | —         | Reads as 0                                     |

## Example Usage

| Task                          | Instructions                                              |
|-------------------------------|-----------------------------------------------------------|
| Start at 10 ms resolution     | `OUT 0x70` with `0x0011`                                  |
| Pause (keep 10 ms)            | `OUT 0x70` with `0x0010`                                  |
| Reset                         | `OUT 0x70` with `0x0002`                                  |
| Read current time             | `IN 0x71`                                                 |
| Record a lap                  | `OUT 0x72` (any value)                                    |
| Read all laps                 | Loop: `IN 0x73`, stop when LAP_CNT = 0, else `IN 0x72`    |
| Start logging button presses  | `OUT 0x74` with `0x0001`                                  |
| Read all logged presses       | Loop: `IN 0x76`, stop when EVT_CNT = 0, else `IN 0x75`    |

## Reserved for Stretch Features (0x77–0x7F)

- Multiple independent stopwatches
- Alarm/compare register
- Lap delta (time since last lap)
- Display-ready (BCD) time format
- Snapshot-safe reads for wider counts
