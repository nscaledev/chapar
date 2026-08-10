#!/usr/bin/env bash
# DESCRIPTION: CPU ISA, vendor, feature, NUMA, PCI, release metadata, and ELF compatibility evidence
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:03:00
#SBATCH --job-name=cpu-platform

# Compares the host CPU against the tracked expectations in
# validation/config/capability.yaml. Expectations come from that reviewed file
# rather than from environment variables, because a suite that learns its
# expectations from the environment can be told to expect whatever it found.
#
# ELF inspection is deliberately limited to machine compatibility. A binary's
# microarchitecture is never inferred from it: an x86-64 ELF says nothing about
# whether it was built for a particular ISA level.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validation_dir="$(cd "${script_dir}/.." && pwd)"
# shellcheck source=validation/lib/verdict.sh
source "${validation_dir}/lib/verdict.sh"
# shellcheck source=validation/lib/result-manifest.sh
source "${validation_dir}/lib/result-manifest.sh"
# shellcheck source=validation/lib/fixture-mode.sh
source "${validation_dir}/lib/fixture-mode.sh"

validation_fixture_guard
fixture="$(validation_fixture_dir VALIDATION_TEST_CPU)"

results_root="${RESULTS_ROOT:-${validation_dir}/results}"
node="${SLURM_NODELIST:-$(hostname -s)}"
validation_result_init cpu-platform "${results_root}" "${node}"
results_dir="${VALIDATION_NODE_DIR}"

export CPU_PLATFORM_FIXTURE="${fixture}"
export CPU_PLATFORM_RESULT="${results_dir}/cpu_platform.json"
export CPU_PLATFORM_CAPABILITY="${validation_dir}/config/capability.yaml"
# The release directory is the concrete immutable release validation/run
# resolved and verified before submission, never a mutable `current` pointer.
export CPU_PLATFORM_RELEASE="${CHAPAR_RELEASE_DIR:-}"

python3 <<'PY'
import json
import os
import pathlib
import platform
import subprocess

import yaml


def output(*command):
    try:
        completed = subprocess.run(command, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        return ""
    return completed.stdout if completed.returncode == 0 else ""


def normalized_architecture(value):
    value = value.lower()
    if value in {"x86_64", "amd64"}:
        return "x86_64"
    if value in {"aarch64", "arm64"}:
        return "aarch64"
    return value


def machine_for_architecture(architecture):
    return "AArch64" if architecture == "aarch64" else "X86-64"


def vendor_for_cpuinfo(cpuinfo, architecture):
    lower = cpuinfo.lower()
    if "genuineintel" in lower or "intel" in lower:
        return "intel"
    if "authenticamd" in lower or "amd" in lower:
        return "amd"
    if "nvidia" in lower and architecture == "aarch64":
        return "nvidia"
    return "generic"


def features_for_cpuinfo(cpuinfo):
    names = ("flags", "features")
    values = set()
    for line in cpuinfo.splitlines():
        key, separator, value = line.partition(":")
        if separator and key.strip().lower() in names:
            values.update(value.strip().lower().split())
    return sorted(values)


def release_architecture(release_dir):
    """The release's declared Spack target from its own metadata.json."""
    if not release_dir:
        return "", ""
    path = pathlib.Path(release_dir) / "metadata.json"
    if not path.is_file():
        return "", f"release metadata is missing: {path}"
    try:
        facts = json.loads(path.read_text(encoding="utf-8"))["target_facts"]
        return str(facts["spack_target"]), ""
    except (ValueError, KeyError, TypeError):
        return "", f"release metadata has no target facts: {path}"


def elf_machines(paths):
    values = []
    for path in paths:
        if not pathlib.Path(path).is_file():
            values.append({"path": path, "machine": "", "error": "not a regular file"})
            continue
        header = output("readelf", "-h", path)
        machine = next(
            (line.split(":", 1)[1].strip() for line in header.splitlines() if line.strip().startswith("Machine:")),
            "",
        )
        values.append({"path": path, "machine": machine, "error": "" if machine else "readelf did not report ELF machine"})
    return values


fixture = os.environ["CPU_PLATFORM_FIXTURE"]
if fixture:
    payload = json.loads((pathlib.Path(fixture) / "manifest.json").read_text(encoding="utf-8"))
    observed = payload["cpu_platform"]
    expected = payload["expected"]
    declared = payload.get("verdicts", {}).get("cpu-platform", "")
else:
    configured = yaml.safe_load(pathlib.Path(os.environ["CPU_PLATFORM_CAPABILITY"]).read_text(encoding="utf-8")) or {}
    cpu_expectations = configured.get("cpu", {}) or {}
    cpuinfo_path = pathlib.Path("/proc/cpuinfo")
    cpuinfo = cpuinfo_path.read_text(encoding="utf-8", errors="replace") if cpuinfo_path.is_file() else ""
    architecture = normalized_architecture(platform.machine())
    release_arch, release_error = release_architecture(os.environ["CPU_PLATFORM_RELEASE"])
    observed = {
        "architecture": architecture,
        "vendor": vendor_for_cpuinfo(cpuinfo, architecture),
        "features": features_for_cpuinfo(cpuinfo),
        "numa_nodes": len(list(pathlib.Path("/sys/devices/system/node").glob("node[0-9]*"))),
        "pci_devices": len(list(pathlib.Path("/sys/bus/pci/devices").glob("*"))),
        "chapar_arch": release_arch,
        "release_error": release_error,
        "elf": elf_machines([str(value) for value in cpu_expectations.get("elf_paths", []) or []]),
    }
    expected = {
        "platform": cpu_expectations.get("platform", ""),
        "vendor": cpu_expectations.get("vendor", ""),
        "features": [str(value).lower() for value in cpu_expectations.get("required_features", []) or []],
        "numa_nodes": cpu_expectations.get("numa_nodes", ""),
        "pci_devices": cpu_expectations.get("pci_devices", ""),
    }
    declared = ""

failures = []
warnings = []
architecture = normalized_architecture(observed["architecture"])
vendor = observed["vendor"].lower()
platform_name = expected.get("platform", "")
if architecture not in {"x86_64", "aarch64"}:
    failures.append(f"unsupported host ISA: {architecture}")
if platform_name:
    expected_platform = {
        "intel-x86": ("x86_64", "intel"),
        "amd-x86": ("x86_64", "amd"),
        "nvidia-grace": ("aarch64", "nvidia"),
        "generic": (architecture, "generic"),
    }.get(platform_name)
    if expected_platform is None:
        failures.append(f"unsupported expected CPU platform: {platform_name}")
    elif architecture != expected_platform[0] or (expected_platform[1] != "generic" and vendor != expected_platform[1]):
        failures.append(f"CPU platform mismatch: expected={platform_name}, architecture={architecture}, vendor={vendor}")
expected_vendor = expected.get("vendor", "")
if expected_vendor and expected_vendor != "generic" and vendor != expected_vendor:
    failures.append(f"CPU vendor mismatch: expected={expected_vendor}, got={vendor}")
missing_features = sorted(set(expected.get("features", [])) - set(observed.get("features", [])))
if missing_features:
    failures.append(f"missing required CPU features: {','.join(missing_features)}")
for key in ("numa_nodes", "pci_devices"):
    value = expected.get(key, "")
    if value not in (None, "") and int(observed[key]) != int(value):
        failures.append(f"{key} mismatch: expected={value}, got={observed[key]}")
release_arch = observed.get("chapar_arch", "")
if observed.get("release_error"):
    failures.append(observed["release_error"])
elif release_arch:
    release_is_arm = "aarch64" in release_arch
    release_is_x86 = any(token in release_arch for token in ("x86_64", "zen", "skylake", "icelake", "sapphirerapids"))
    if not release_is_arm and not release_is_x86:
        failures.append(f"release target has no supported CPU ISA: {release_arch}")
    elif release_is_arm != (architecture == "aarch64"):
        failures.append(f"release target is incompatible with host ISA: {release_arch} vs {architecture}")
    elif "zen" in release_arch and vendor != "amd":
        failures.append(f"release requires an AMD Zen target but host vendor is {vendor}")
elif not fixture:
    warnings.append("no release directory was supplied; release target compatibility was not evaluated")
expected_machine = machine_for_architecture(architecture)
for elf in observed.get("elf", []):
    if elf["error"]:
        failures.append(f"ELF inspection failed for {elf['path']}: {elf['error']}")
    elif expected_machine not in elf["machine"]:
        failures.append(f"ELF machine is incompatible with host ISA: {elf['path']} reports {elf['machine']}")
if not observed.get("elf") and not fixture:
    warnings.append("capability config declared no cpu.elf_paths; ELF compatibility was not evaluated")

verdict = "FAIL" if failures else "WARN" if warnings else "PASS"
if declared and verdict != declared:
    failures.append(f"fixture declared {declared} but validation produced {verdict}")
    verdict = "FAIL"
payload = {
    "fixture": bool(fixture), "expected": expected, "observed": observed,
    "verdict": verdict, "failures": failures, "warnings": warnings,
    "elf_scope": "ELF machine compatibility only; CPU microarchitecture is never inferred from ELF",
}
pathlib.Path(os.environ["CPU_PLATFORM_RESULT"]).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

verdict="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['verdict'])" "${results_dir}/cpu_platform.json")"
reason="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('; '.join(d['failures'] or d['warnings']))" "${results_dir}/cpu_platform.json")"
case "${verdict}" in
    FAIL) validation_threshold_violation "${reason}" ;;
    WARN) validation_set_verdict WARN "${reason}" ;;
esac

printf 'CPU platform evidence written to %s\n' "${results_dir}" >&2
