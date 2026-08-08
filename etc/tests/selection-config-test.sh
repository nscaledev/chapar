#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_BASE="$(cd -P "${TMPDIR:-/tmp}" && pwd)"
TMP="$(mktemp -d "${TMP_BASE}/chapar-selection-test.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT
FIXTURE_ROOT="${TMP}/repo"
mkdir -p "${FIXTURE_ROOT}/etc" "${FIXTURE_ROOT}/ci" \
  "${FIXTURE_ROOT}/envs/software" "${FIXTURE_ROOT}/containers/images"
cp "${ROOT}/etc/chapar-selection.sh" "${ROOT}/etc/chapar-install-tree.sh" "${FIXTURE_ROOT}/etc/"
cp "${ROOT}/ci/push-buildcache.sh" "${FIXTURE_ROOT}/ci/"
cp "${ROOT}/envs/software/spack.yaml" "${FIXTURE_ROOT}/envs/software/"
cp "${ROOT}/containers/images/targets.json" "${ROOT}/containers/images/containers.json" \
  "${FIXTURE_ROOT}/containers/images/"
HELPER="${FIXTURE_ROOT}/etc/chapar-selection.sh"
PUSH="${FIXTURE_ROOT}/ci/push-buildcache.sh"
UV_RUN=(uv run --offline --with 'cookiecutter>=2,<3' --with 'pydantic>=2,<3' --with 'PyYAML>=6,<7' --with 'jsonschema>=4,<5')

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

"${UV_RUN[@]}" python3 - "${ROOT}" "${FIXTURE_ROOT}" "${TMP}" <<'PY'
import json
import sys
from pathlib import Path

import yaml

root, fixture, temp = map(Path, sys.argv[1:])
sys.path.insert(0, str(root))
from tools.chapar_datacenter_models import DatacenterContext
from tools.chapar_datacenter_rendering import build_payload

context = yaml.safe_load((root / "cookiecutter/chapar-datacenter/examples/example-context.yaml").read_text())
for target in context["targets"]:
    for group in ("durable_writable", "temporary"):
        for name in target["paths"][group]:
            target["paths"][group][name] = str(temp / "managed" / target["target"] / name)
    target["paths"]["temporary"]["release_staging"] = str(
        Path(target["paths"]["durable_writable"]["releases"]) / ".staging"
    )
    for item in target["paths"]["read_only_inputs"]:
        if item["kind"] == "seed_mirror":
            item["path"] = str(temp / "seed" / target["target"])
    target["publication"]["publish_buildcache"] = True
payload = build_payload(DatacenterContext.model_validate(context))
dc_root = fixture / "datacenters/example-lab"
(dc_root / "targets").mkdir(parents=True)
(dc_root / "datacenter.json").write_text(json.dumps(payload.datacenter, indent=2, sort_keys=True) + "\n")
for target, document in payload.contracts.items():
    destination = dc_root / "targets" / target / "contract.json"
    destination.parent.mkdir(parents=True)
    destination.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
PY

OUTPUT="${TMP}/selection"
"${UV_RUN[@]}" python3 "${ROOT}/tools/chapar_resolve.py" \
  --catalog "${FIXTURE_ROOT}/envs/software/spack.yaml" \
  --targets "${FIXTURE_ROOT}/containers/images/targets.json" \
  --containers "${FIXTURE_ROOT}/containers/images/containers.json" \
  --datacenter "${FIXTURE_ROOT}/datacenters/example-lab/datacenter.json" \
  --datacenter-id example-lab \
  --contract "${FIXTURE_ROOT}/datacenters/example-lab/targets/linux-x86_64-v4/contract.json" \
  --software-set vlad --target linux-x86_64-v4 \
  --release-id release-qa --run-id run-qa --output-dir "${OUTPUT}" >/dev/null
SELECTION="${OUTPUT}/selection.json"
CONTRACT="${FIXTURE_ROOT}/datacenters/example-lab/targets/linux-x86_64-v4/contract.json"
DIGEST="$(sha256_file "${SELECTION}")"

"${HELPER}" render-scopes "${SELECTION}" "${DIGEST}" "${CONTRACT}" "${TMP}/scope"
grep -Fq 'autopush: true' "${TMP}/scope/mirrors.yaml"
# Spack appends <platform-os-target> under the module root, so the rendered root
# is the release-local modulefiles directory. The selection's `modulefiles` path
# is the published pointer to one architecture directory inside it, and using it
# as a root would nest a second architecture level.
grep -Fq "$(jq -r .paths.release_final "${SELECTION}")/modulefiles" "${TMP}/scope/modules.yaml"
grep -Fq 'padded_length:' "${TMP}/scope/config.yaml"

# The install-tree projection is a three-way contract: the persistent user scope,
# the two rendered scopes, and containers/images/build-image.sh, which resolves
# store prefixes by walking it. Assert the rendered value, then assert every
# tracked declaration agrees, so none of them can drift alone.
PROJECTION='all: "{architecture.platform}-{architecture.target}/{name}-{version}-{hash}"'
grep -Fq "${PROJECTION}" "${TMP}/scope/config.yaml"
for declaration in "${ROOT}/etc/user/base/config.yaml" "${ROOT}/envs/software/release.sh" \
  "${ROOT}/etc/chapar-selection.sh"; do
  grep -Fq "${PROJECTION}" "${declaration}" ||
    { echo "install-tree projection drifted in ${declaration}" >&2; exit 1; }
done

# render_scopes and release.sh make_scope had diverged: one declared `enable:`
# without the tcl options, the other the tcl options without `enable:`, so which
# tool rendered a release decided whether hash_length, exclude_implicits and
# autoload applied to its modulefiles. Both must now carry all of it.
grep -Fq 'enable: [tcl]' "${TMP}/scope/modules.yaml"
grep -Fq 'exclude_implicits: true' "${TMP}/scope/modules.yaml"
grep -Fq 'hash_length: 0' "${TMP}/scope/modules.yaml"
grep -Fq 'autoload: none' "${TMP}/scope/modules.yaml"

mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/spack" <<'MOCK'
#!/usr/bin/env bash
touch "${CHAPAR_FORBIDDEN_COMMAND_MARKER}"
exit 97
MOCK
chmod +x "${TMP}/bin/spack"
PATH="${TMP}/bin:${PATH}" CHAPAR_FORBIDDEN_COMMAND_MARKER="${TMP}/spack-called" \
  "${PUSH}" --selection "${SELECTION}" --selection-sha256 "${DIGEST}" \
  --contract "${CONTRACT}" --plan >"${TMP}/push-plan.txt"
grep -Fq 'action: plan only; no cache command or filesystem mutation' "${TMP}/push-plan.txt"
test ! -e "${TMP}/spack-called"

cp "${CONTRACT}" "${TMP}/forged-contract.json"
jq --arg root "${TMP}/foreign" \
  '.paths.durable_writable.writable_buildcache=$root' \
  "${TMP}/forged-contract.json" >"${TMP}/forged-contract.next"
mv "${TMP}/forged-contract.next" "${TMP}/forged-contract.json"
jq --arg digest "$(sha256_file "${TMP}/forged-contract.json")" \
  --arg root "${TMP}/foreign/example-lab/vlad/linux-x86_64-v4" \
  '.authorities.target_contract=$digest | .paths.writable_buildcache=$root' \
  "${SELECTION}" >"${TMP}/forged-selection.json"
if "${PUSH}" --selection "${TMP}/forged-selection.json" \
  --selection-sha256 "$(sha256_file "${TMP}/forged-selection.json")" \
  --contract "${TMP}/forged-contract.json" --plan \
  >"${TMP}/forged.out" 2>"${TMP}/forged.err"; then
  echo 'forged self-digested selection and contract were accepted' >&2
  exit 1
fi
grep -Fq 'canonical datacenter authority' "${TMP}/forged.err"
test ! -s "${TMP}/forged.out"
test ! -e "${TMP}/foreign"
test ! -e "${TMP}/spack-called"

cp "${FIXTURE_ROOT}/containers/images/targets.json" "${TMP}/targets.good"
printf '\n' >>"${FIXTURE_ROOT}/containers/images/targets.json"
if "${HELPER}" verify "${SELECTION}" "${DIGEST}" "${CONTRACT}" \
  >"${TMP}/authority.out" 2>"${TMP}/authority.err"; then
  echo 'target-registry drift was accepted' >&2
  exit 1
fi
grep -Fq 'canonical authorities' "${TMP}/authority.err"
mv "${TMP}/targets.good" "${FIXTURE_ROOT}/containers/images/targets.json"

printf '\n' >>"${OUTPUT}/spack.yaml"
if "${HELPER}" verify "${SELECTION}" "${DIGEST}" "${CONTRACT}" \
  >"${TMP}/artifact.out" 2>"${TMP}/artifact.err"; then
  echo 'effective-manifest drift was accepted' >&2
  exit 1
fi
grep -Fq 'artifact digests' "${TMP}/artifact.err"

echo 'selection config fixtures: PASS'
