# Chapar container delivery

`containers/images/targets.json` is the target registry and
`containers/images/containers.json` is the container registry. Consumers must
load them; duplicated base/target dictionaries are not authority.

| Public container | Accepted set | Allowed targets |
|---|---|---|
| `nvidia-vlad` | `vlad` | `linux-x86_64-generic`, `linux-x86_64-v4`, `linux-aarch64-generic`, `linux-aarch64-gb300` |
| `ubuntu-hpcsim` | `hpcsim` | `linux-x86_64-generic` |

`nvidia-vlad` covers both a generic and a microarchitecture-specific target per
ISA. The generic pair (`spack_target` `x86_64` and `aarch64`) is the portable
delivery; `linux-x86_64-v4` and `linux-aarch64-gb300` narrow the ISA level and
the CUDA architecture list respectively. All four share their base image's OCI
platform descriptor and differ only in the Spack tree layered on top.

Every target contract that selects a container must declare its `install_tree`
under the reserved `/opt/chapar` namespace. Injection copies each store prefix
into the image at its identical absolute path, so the store root is at once a
builder path and an in-image path; confining it keeps it from colliding with the
base image's own content. Builders must provide `/opt/chapar` as a bind mount
onto real storage, not a symlink — image planning rejects a store root with a
symlinked component.

The selected release is produced from `envs/software/spack.yaml` plus a
reviewed `datacenters/<id>` target contract. Image planning verifies immutable
selection, contract, registry, effective-manifest, target-policy,
release-metadata, and release-local-lock digests. Injection preserves exact
build-time prefixes, includes link/run closure, and exposes one opt-in module
destination.

`containers/images/sources-lock.json` is globally `blocked`; no image import,
export, candidate write, or publication is currently permitted. Internal
`vlad-image` runtime paths/units/variables remain for compatibility and do not
define another public container.

Use `README.md` for the canonical disposable offline flow. Plan-only image
fixtures live under `containers/images/tests/`; they do not prove a production
image build. `/resources/chapar/vlad` and `/resources/chapar/hpcsim` remain
immutable legacy shadow/canary roots with no migration or retirement approval.
Offline contract and selection behavior is verified; target-platform behavior
not validated.
