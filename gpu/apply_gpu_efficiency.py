#!/usr/bin/env python3
import pathlib
import re
import sys

if len(sys.argv) != 4:
    raise SystemExit("usage: apply_gpu_efficiency.py HEADER UNDERVOLT_STEP IDLE_OPP")

header = pathlib.Path(sys.argv[1])
undervolt = int(sys.argv[2])
idle_choice = sys.argv[3]

IDLE_OPP_OPTIONS = {
    "390": None,
    "300": (300000, "POSDIV_POWER_8"),
    "250": (250000, "POSDIV_POWER_8"),
    "187.5": (187500, "POSDIV_POWER_8"),
}
if idle_choice not in IDLE_OPP_OPTIONS:
    raise SystemExit("Idle OPP must be 390, 300, 250, or 187.5 MHz")

PMIC_STEP = 625
VGPU_MIN = 50000
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

if undervolt not in {0, 625, 1250, 1875}:
    raise SystemExit("Undervolt step must be 0, 625, 1250, or 1875")
if undervolt % PMIC_STEP:
    raise SystemExit("Undervolt step is not aligned to the PMIC step")

text = header.read_text()
text, avs_count = re.subn(
    r"(?m)^#define GPUFREQ_AVS_ENABLE\s+\(1\)",
    "#define GPUFREQ_AVS_ENABLE              (0)",
    text,
)
if avs_count != 1:
    raise SystemExit(f"Expected one enabled GPUFREQ_AVS_ENABLE macro, found {avs_count}")

table = re.search(
    r"(struct gpufreq_opp_info g_default_gpu\[\] = \{)(.*?)(\n\};)",
    text,
    re.S,
)
if not table:
    raise SystemExit("Cannot locate g_default_gpu")

body = table.group(2)
pattern = re.compile(
    r"GPUOP\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,"
    r"\s*([^,]+)\s*,\s*(\d+)\s*,\s*(\d+)\s*\)"
)
matches = list(pattern.finditer(body))
if len(matches) < 45:
    raise SystemExit(f"Expected at least 45 GPU OPPs, found {len(matches)}")
if set(BASELINE) - {int(m.group(1)) for m in matches}:
    raise SystemExit("Stock GPU OPP frequencies do not match the validated MT6789 table")
if sum(int(m.group(1)) == 390000 for m in matches) != 1:
    raise SystemExit("Expected exactly one stock 390 MHz OPP")
if any(int(m.group(1)) < 390000 for m in matches):
    raise SystemExit("An idle OPP already exists. Refusing to append a duplicate")

def rewrite_opp(match):
    freq = int(match.group(1))
    old_volt = int(match.group(2))
    aging = int(match.group(5))
    power = int(match.group(6))

    if freq in BASELINE:
        volt = BASELINE[freq]
    elif freq > 1100000:
        volt = old_volt - 7500
    else:
        raise SystemExit(f"Unexpected OPP frequency: {freq}")

    volt = max(VGPU_MIN, volt - undervolt)
    vsram = volt if volt > 75000 else VSRAM_FIXED
    return f"GPUOP({freq}, {volt}, {vsram}, {match.group(4).strip()}, {aging}, {power})"

body = pattern.sub(rewrite_opp, body)
idle = IDLE_OPP_OPTIONS[idle_choice]
if idle:
    idle_freq, idle_posdiv = idle
    if idle_freq < 187500 or idle_freq > 475000:
        raise SystemExit("Idle OPP is outside the supported POSDIV8 range")
    idle_volt = max(VGPU_MIN, 55000 - undervolt)
    idle_vsram = VSRAM_FIXED
    body = body.rstrip() + (
        f"\n\tGPUOP({idle_freq}, {idle_volt}, {idle_vsram}, "
        f"{idle_posdiv}, 625, 0), /* appended idle OPP */\n"
    )

text = text[:table.start(2)] + body + text[table.end(2):]

aging = re.search(
    r"(unsigned int g_aging_table\[\]\[SIGNED_OPP_GPU_NUM\] = \{)(.*?)(\n\};)",
    text,
    re.S,
)
if not aging:
    raise SystemExit("Cannot locate g_aging_table")

def extend_aging_row(match):
    row = int(match.group(1))
    raw = re.sub(r"/\*.*?\*/|//[^\n]*", "", match.group(2), flags=re.S)
    values = [value.strip() for value in raw.split(",") if value.strip()]
    expected = len(matches)
    if len(values) != expected:
        raise SystemExit(f"Aging row {row}: expected {expected} values, found {len(values)}")
    values.append("625" if row == 0 and idle else "0")
    return "{ /* aging table " + str(row) + " */\n\t\t" + ", ".join(values) + ",\n\t}"

aging_body, row_count = re.subn(
    r"\{\s*/\*\s*aging table (\d+)\s*\*/(.*?)\}",
    extend_aging_row,
    aging.group(2),
    flags=re.S,
)
if row_count != 4:
    raise SystemExit(f"Expected four aging rows, found {row_count}")
text = text[:aging.start(2)] + aging_body + text[aging.end(2):]

final_table = re.search(
    r"struct gpufreq_opp_info g_default_gpu\[\] = \{(.*?)\n\};",
    text,
    re.S,
)
final_entries = list(pattern.finditer(final_table.group(1)))
expected_count = len(matches) + (1 if idle else 0)
if len(final_entries) != expected_count:
    raise SystemExit(f"Expected {expected_count} final OPPs, found {len(final_entries)}")

freqs = [int(entry.group(1)) for entry in final_entries]
if any(freqs[i] <= freqs[i + 1] for i in range(len(freqs) - 1)):
    raise SystemExit("GPU frequencies are not strictly descending")
if idle and (freqs[-1] != idle[0] or final_entries[-1].group(4).strip() != idle[1]):
    raise SystemExit("Appended idle OPP does not match the selected frequency/divider")

header.write_text(text)
print("GPU battery-efficiency tuning applied.")
print("AVS: disabled. Stock OPP voltages: rebased to the supplied runtime table.")
print(f"Undervolt: {undervolt / 100:.2f} mV per OPP.")
print(f"Existing 390 MHz OPP retained. Appended idle OPP: {idle_choice} MHz.")
print(f"Final signed GPU OPP count: {expected_count}.")
