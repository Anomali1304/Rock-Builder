#!/usr/bin/env python3
import pathlib
import re
import sys

if len(sys.argv) != 4:
    raise SystemExit("usage: apply_gpu_efficiency.py HEADER MIN_FREQ_MHZ UNDERVOLT_STEP")

header = pathlib.Path(sys.argv[1])
min_mhz = int(sys.argv[2])
undervolt = int(sys.argv[3])

ALLOWED_MIN = {365, 340, 315, 290}
PMIC_STEP = 625
VGPU_MIN = 50000
VSRAM_THRESHOLD = 75000
VSRAM_FIXED = 75000
BASELINE = {
    1100000: 77500, 1086000: 77500, 1072000: 76875,
    1058000: 76250, 1045000: 75625, 1031000: 75000,
    1017000: 74375, 1003000: 73750, 990000: 73125,
    976000: 72500, 962000: 72500, 948000: 71875,
    935000: 71250, 921000: 70625, 907000: 70000,
    893000: 69375, 880000: 68750, 868000: 68125,
    857000: 68125, 846000: 67500, 835000: 66875,
    823000: 66250, 812000: 66250, 801000: 65625,
    790000: 65000, 778000: 65000, 767000: 64375,
    756000: 63750, 745000: 63125, 733000: 63125,
    722000: 62500, 711000: 61875, 700000: 61250,
    674000: 61250, 648000: 60625, 622000: 60625,
    596000: 60000, 570000: 60000, 545000: 59375,
    519000: 59375, 493000: 58750, 467000: 58750,
    441000: 58125, 415000: 58125, 390000: 57500,
}

if min_mhz not in ALLOWED_MIN:
    raise SystemExit(f"Unsupported minimum GPU frequency: {min_mhz} MHz")
if undervolt not in {0, 625, 1250, 1875}:
    raise SystemExit("Undervolt step must be 0, 625, 1250, or 1875 (units of 10 uV)")
if undervolt % PMIC_STEP:
    raise SystemExit("Undervolt step is not aligned to the PMIC step")

text = header.read_text()
macro, count = re.subn(
    r"(?m)^#define GPUFREQ_AVS_ENABLE\\s+\\(1\\)",
    "#define GPUFREQ_AVS_ENABLE              (0)",
    text,
)
if count != 1:
    raise SystemExit(f"Expected one enabled GPUFREQ_AVS_ENABLE macro, found {count}")
text = macro

table = re.search(
    r"(struct gpufreq_opp_info g_default_gpu\\[\\] = \\{)(.*?)(\\n\\};)",
    text,
    re.S,
)
if not table:
    raise SystemExit("Cannot locate g_default_gpu")
body = table.group(2)
pattern = re.compile(
    r"GPUOP\\(\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,"
    r"\\s*([^,]+)\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*\\)"
)
matches = list(pattern.finditer(body))
if len(matches) < 45:
    raise SystemExit(f"Expected at least 45 GPU OPPs, found {len(matches)}")
if set(BASELINE) - {int(m.group(1)) for m in matches}:
    raise SystemExit("The stock GPU OPP frequencies do not match the validated MT6789 table")

old_count = len(matches)
low_freqs = list(range(390000 - 25000, min_mhz * 1000 - 1, -25000))
if not low_freqs or low_freqs[-1] != min_mhz * 1000:
    raise SystemExit("Low-frequency OPP generation failed")

def rewrite_opp(match):
    freq = int(match.group(1))
    old_volt = int(match.group(2))
    posdiv = match.group(4).strip()
    aging = int(match.group(5))
    power = int(match.group(6))

    if freq in BASELINE:
        volt = BASELINE[freq]
    elif freq > 1100000:
        # The existing OC generator extrapolates from the stock 850 mV table.
        # Rebase those generated OPPs to the measured 775 mV runtime anchor.
        volt = old_volt - 7500
    else:
        raise SystemExit(f"Unexpected OPP frequency: {freq}")

    volt = max(VGPU_MIN, volt - undervolt)
    vsram = volt if volt > VSRAM_THRESHOLD else VSRAM_FIXED
    return f"GPUOP({freq}, {volt}, {vsram}, {posdiv}, {aging}, {power})"

body = pattern.sub(rewrite_opp, body)
if len(pattern.findall(body)) != old_count:
    raise SystemExit("GPU OPP rewrite changed the number of existing entries")

low_lines = []
for freq in low_freqs:
    volt = max(VGPU_MIN, 57500 - undervolt)
    vsram = volt if volt > VSRAM_THRESHOLD else VSRAM_FIXED
    low_lines.append(
        f"\\tGPUOP({freq}, {volt}, {vsram}, POSDIV_POWER_8, 625, 0), "
        "/* battery-efficiency low OPP */"
    )
body = body.rstrip() + "\\n" + "\\n".join(low_lines)
text = text[:table.start(2)] + body + text[table.end(2):]

aging = re.search(
    r"(unsigned int g_aging_table\\[\\]\\[SIGNED_OPP_GPU_NUM\\] = \\{)(.*?)(\\n\\};)",
    text,
    re.S,
)
if not aging:
    raise SystemExit("Cannot locate g_aging_table")

def extend_aging_row(match):
    row = int(match.group(1))
    row_body = re.sub(r"/\\*.*?\\*/|//[^\\n]*", "", match.group(2), flags=re.S)
    values = [value.strip() for value in row_body.split(",") if value.strip()]
    if len(values) != old_count:
        raise SystemExit(
            f"Aging row {row}: expected {old_count} values, found {len(values)}"
        )
    values.extend(["625" if row == 0 else "0"] * len(low_freqs))
    return (
        "{ /* aging table " + str(row) + " */\\n\\t\\t"
        + ", ".join(values) + ",\\n\\t}"
    )

aging_body, rows = re.subn(
    r"\\{\\s*/\\*\\s*aging table (\\d+)\\s*\\*/(.*?)\\}",
    extend_aging_row,
    aging.group(2),
    flags=re.S,
)
if rows != 4:
    raise SystemExit(f"Expected four aging rows, found {rows}")
text = text[:aging.start(2)] + aging_body + text[aging.end(2):]

# Verify the final OPP ordering, divider boundary, and regulator constraints.
final_matches = list(pattern.finditer(body))
entries = [(int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4).strip())
           for m in final_matches]
if len(entries) != old_count + len(low_freqs):
    raise SystemExit("Final GPU OPP count mismatch")
if any(entries[i][0] <= entries[i + 1][0] for i in range(len(entries) - 1)):
    raise SystemExit("GPU frequencies are not strictly descending")
for freq, volt, vsram, posdiv in entries:
    if volt < VGPU_MIN or volt % PMIC_STEP:
        raise SystemExit(f"Invalid VGPU at {freq} kHz: {volt}")
    if not 0 <= vsram - volt <= 20000:
        raise SystemExit(f"Invalid VSRAM/VGPU delta at {freq} kHz")
    if freq < 375000 and posdiv != "POSDIV_POWER_8":
        raise SystemExit(f"OPP {freq} kHz must use POSDIV_POWER_8")
    if freq >= 375000 and freq <= 475000 and posdiv not in {
        "POSDIV_POWER_4", "POSDIV_POWER_8"
    }:
        raise SystemExit(f"Invalid post-divider at {freq} kHz")

header.write_text(text)
print("GPU battery-efficiency tuning applied.")
print("AVS: disabled. Stock OPP voltages: rebased to the supplied runtime table.")
print(f"Undervolt: {undervolt / 100:.2f} mV per OPP.")
print(f"Added {len(low_freqs)} low OPPs: {', '.join(str(f // 1000) for f in low_freqs)} MHz.")
print(f"Final signed GPU OPP count: {len(entries)}.")
