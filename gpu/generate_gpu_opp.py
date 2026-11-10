#!/usr/bin/env python3
import math
import pathlib
import re
import sys

header = pathlib.Path(sys.argv[1])
target_mhz = int(sys.argv[2])
text = header.read_text()
BASE_MHZ, STEP_MHZ, MAX_MHZ = 1100, 25, 1500
PMIC_STEP, MAX_VOLT = 625, 129300

if target_mhz < BASE_MHZ or target_mhz > MAX_MHZ or target_mhz % STEP_MHZ:
    raise SystemExit("GPU target must be 1100-1500 MHz in 25 MHz steps")

table = re.search(r"(struct gpufreq_opp_info g_default_gpu\[\] = \{)(.*?)(\n\};)", text, re.S)
if not table:
    raise SystemExit("Cannot locate g_default_gpu")
body = table.group(2)
matches = re.findall(r"GPUOP\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([^,]+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)", body)
if len(matches) != 45:
    raise SystemExit(f"Expected 45 stock OPPs, found {len(matches)}")
stock = [(int(f), int(v), int(vs), p.strip(), int(a), int(w)) for f,v,vs,p,a,w in matches]
if stock[0][0] != 1100000 or any(stock[i][0] <= stock[i+1][0] for i in range(44)):
    raise SystemExit("Unexpected stock OPP ordering")

freqs = list(range(1125000, target_mhz * 1000 + 1, 25000))
count = len(freqs)
if not count:
    print("GPU OC disabled. Stock OPP table retained.")
    raise SystemExit(0)

samples = stock[:5]
mf = sum(x[0] for x in samples) / 5
mv = sum(x[1] for x in samples) / 5
slope = sum((x[0]-mf)*(x[1]-mv) for x in samples) / sum((x[0]-mf)**2 for x in samples)
if slope >= 0:
    raise SystemExit("Invalid stock voltage slope")

generated = []
last_v = stock[0][1]
for freq in freqs:
    raw_v = mv + slope * (freq-mf)
    volt = max(int(math.ceil(raw_v / PMIC_STEP) * PMIC_STEP), last_v + PMIC_STEP)
    if volt > MAX_VOLT:
        raise SystemExit(f"Calculated voltage {volt} exceeds PMIC limit {MAX_VOLT}")
    generated.append((freq, volt, volt, stock[0][3], stock[0][4], 0))
    last_v = volt

generated.reverse()

lines = []
for i, (freq, volt, vsram, posdiv, aging, power) in enumerate(generated):
    lines.append(f"\tGPUOP({freq}, {volt}, {vsram}, {posdiv}, {aging}, {power}), /* {i:2d} generated */")
body = "\n" + "\n".join(lines) + body
body = re.sub(r"/\*\s*(\d+)(\s*(?:sign off)?)\s*\*/",
              lambda m: f"/* {int(m.group(1))+count:2d}{m.group(2)} */", body)
text = text[:table.start(2)] + body + text[table.end(2):]

for name in ("g_segment_adj", "g_mcl50_adj", "g_avs_adj"):
    pattern = rf"(struct gpufreq_adj_info {name}\[\] = \{{)(.*?)(\n\}};)"
    match = re.search(pattern, text, re.S)
    if not match:
        raise SystemExit(f"Cannot locate {name}")
    adjusted = re.sub(r"ADJOP\(\s*(\d+)\s*,",
                      lambda m: f"ADJOP({int(m.group(1))+count},", match.group(2))
    text = text[:match.start(2)] + adjusted + text[match.end(2):]

aging = re.search(r"(unsigned int g_aging_table\[\]\[SIGNED_OPP_GPU_NUM\] = \{)(.*?)(\n\};)", text, re.S)
if not aging:
    raise SystemExit("Cannot locate g_aging_table")
def extend_row(m):
    row = int(m.group(1))
    vals = [v.strip() for v in m.group(2).split(",") if v.strip()]
    if len(vals) != 45:
        raise SystemExit(f"Aging row {row}: expected 45 values, found {len(vals)}")
    vals = (["1875" if row == 0 else "0"] * count) + vals
    return "{ /* aging table " + str(row) + " */\n\t\t" + ", ".join(vals) + ",\n\t}"
aging_body, row_count = re.subn(r"\{\s*/\*\s*aging table (\d+)\s*\*/(.*?)\}",
                                extend_row, aging.group(2), flags=re.S)
if row_count != 4:
    raise SystemExit(f"Expected four aging rows, found {row_count}")
text = text[:aging.start(2)] + aging_body + text[aging.end(2):]

if any(generated[i][0] <= generated[i+1][0] for i in range(len(generated)-1)):
    raise SystemExit("Generated frequency order invalid")
if any(v % PMIC_STEP or vs-v < 0 or vs-v > 20000 for _,v,vs,_,_,_ in generated):
    raise SystemExit("Generated voltage validation failed")

header.write_text(text)
print(f"Added {count} OPPs up to {target_mhz} MHz. AVS, aging, segment and MCL50 indices updated.")
print("Voltage uses linear extrapolation from the first five stock OPPs, rounded up to PMIC steps.")
