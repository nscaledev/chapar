# Chapar configuration scopes

`etc/system/` and `etc/user/` contain persistent Spack scope policy. They do
not own software selection, target facts, data-center paths, or publication
policy.

Authority order remains `defaults > system > site > user > spack > environment
> command line`, but the active software catalog is
`envs/software/spack.yaml`. The resolver combines it with the target registry,
container registry, and reviewed `datacenters/<id>` target contract. It emits
an effective `spack.yaml`, `target-policy.yaml`, `selection.json`, and
`selection.sha256`; consumers use only that exact set.

`etc/init.sh` binds repository scopes. It must not turn ambient variables or a
local site file into selection authority. `etc/chapar-selection.sh` verifies a
selection/contract pair and renders temporary release scopes.

## Scope invariants

Architecture comes from target-registry facts, never from inspecting the running
machine. `etc/system/include.yaml` and `etc/user/include.yaml` select an OS
overlay with Spack's own `when: os == "<id>"` condition, and everything
architecture-shaped -- `spack_target`, `llvm_targets`, `cuda_arch`,
`oci_platform` -- reaches Spack only as resolver-emitted package requirements
derived from `containers/images/targets.json`. A scope must not read
`/etc/os-release` to reach the same conclusion twice.

`config:install_tree:projections:all` is upstream Spack's default,
`{architecture.platform}-{architecture.target}/{name}-{version}-{hash}`. It is
declared in `etc/user/base/config.yaml` and rendered identically by
`envs/software/release.sh` and `etc/chapar-selection.sh`, and
`containers/images/build-image.sh` resolves store prefixes by walking it. The
architecture component is load-bearing: a contract may opt into
`shared_path_classes: [install_tree]` with `share_across_targets`, which drops
the per-target namespace from the derived store path, and container injection
copies store prefixes into an image at their identical absolute path.
`etc/tests/selection-config-test.sh` asserts all four agree.

`config:shared_linking` stays `type: rpath` with `bind: false`, and neither value
is a free choice:

- `rpath` (not `runpath`) is inherited down the dependency chain and outranks
  `LD_LIBRARY_PATH`, so a base container image's own `LD_LIBRARY_PATH` cannot
  hijack an injected Chapar binary. `runpath` would invert that precedence.
- `bind: true` would embed the absolute path of every dependent library directly
  in the ELF. Injected stacks resolve `libcuda.so.1` and `libnvidia-*` at run
  time from the NVIDIA container hook, at a path that is not the builder's, so
  binding them at build time is wrong by construction.

`config:license_dir` is deliberately left at Spack's default. No catalog root is
license-gated (`intel-oneapi-mpi` needs no license file), and the only values
available to a persistent scope here are ambient variables -- which is precisely
the defect that `config:environments_root` demonstrated: it named
`$HPCSIM_HOME_ROOT`, which no live path in this repository sets -- it survives
only in the retired `envs/hpcsim` site example -- so the key expanded to the
literal `/environments`. A path class in the target contract, not an ambient
variable, is the way to introduce one if a license-gated root ever appears.

`etc/system/base/mirrors.yaml` declares the source mirror only. Binary mirror
identity is per selection: the ordered read-only `chapar-seed-NNN` inputs and the
single writable `chapar-buildcache` with autopush are rendered from the verified
target contract, never committed to a persistent scope.

The contract path classes are durable writable, ordered read-only, and
temporary. Mutable paths are tuple-namespaced and cannot overlap immutable
legacy shadow/canary roots `/resources/chapar/vlad` or
`/resources/chapar/hpcsim`. No migration or retirement is authorized.

For the complete disposable render/resolver/plan flow, use the single sequence
in `README.md`. Platform config-blame, concretization, build, promotion, module,
and shared-filesystem checks are deferred to an approved Ubuntu 24.04 target
session. Offline contract and selection behavior is verified; target-platform
behavior not validated.
