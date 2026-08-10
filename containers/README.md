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

Both containers fix their module destination at `/opt/chapar/modulefiles`, and
a site that delivers containers should place its install tree
(`CHAPAR_INSTALL_TREE_ROOT`) under the same reserved `/opt/chapar` namespace.
Injection copies each store prefix into the image at its identical absolute
path, so the store root is at once a builder path and an in-image path;
confining it keeps it from colliding with the base image's own content.
Builders must provide `/opt/chapar` as a bind mount onto real storage, not a
symlink — image planning rejects a store root with a symlinked component.

An injected release is produced from `envs/software/spack.yaml` under the
site settings (`etc/README.md`). `chapar image build` verifies the release
directory — metadata identity, recorded digests against the bytes on disk,
and recorded target facts against the registry — before planning anything.
Injection preserves exact build-time prefixes, includes the link/run closure,
and exposes one opt-in module destination. The full operator flow is
`docs/container-images.md`; the mechanism is `docs/container-injection.md`.

`containers/images/sources-lock.json` is globally `blocked`; no image import,
export, candidate write, or publication is currently permitted until every
source category is resolved with immutable digests and the lock is recorded
as `complete`.

Plan modes (`chapar image build --plan-only`, `chapar image preflight
--plan-only`) and the pytest suites under `tests/image` exercise the offline
behavior; they do not prove a production image build. `/resources/chapar/vlad`
and `/resources/chapar/hpcsim` remain immutable legacy shadow/canary roots
with no migration or retirement approval.
