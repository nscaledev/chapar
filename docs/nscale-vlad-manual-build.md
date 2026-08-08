# Manual nscale/Vlad source, release, and image gates

This runbook records custody and approval boundaries. It does not authorize a
platform build. The only runnable offline render/resolver/plan sequence is in
`README.md`.

## Selected identity

Vlad delivery means software set `vlad` plus a registry-approved target and the
public container `nvidia-vlad`. `ubuntu-hpcsim` remains the public HPCSim
container. Historical internal `vlad-image` paths, units, and variable names
remain compatible; they are not a third public container ID.

The resolver must consume `envs/software/spack.yaml`, both global registries,
and a reviewed `datacenters/<id>` snapshot. Its immutable artifact set is
`selection.json`, recorded `selection.sha256`, effective `spack.yaml`, and
`target-policy.yaml`, bound to data center, software set, target, release ID,
run ID, authorities, and selected containers. Release/image receipts must also
bind release-local `spack.lock` bytes and metadata.

## Source custody

`containers/images/sources-lock.json` is global and remains `blocked`. A base
category being individually resolved does not permit any image build. Future
approval must resolve every category and descriptor, preserve role separation,
and verify checkout/source/release/selection/contract/registry digests before
candidate or final writes.

Custody remains split between the builder, validator, and publisher. The
canonical receipt tool is `ci/verify-vlad-source-approval.py`; its exact strict
schema keys are:

- `chapar-vlad-source-approval/v1`: `approved_at,approved_by,change_ticket,chapar_commit,chapar_remote,schema,source_lock_path,source_lock_sha256`
- `chapar-vlad-release-binding/v1`: `chapar_commit,container_registry_sha256,datacenter,datacenter_contract_sha256,effective_manifest_sha256,metadata_path,metadata_sha256,release_dir,release_id,run_id,schema,selection_sha256,software_catalog_sha256,software_set,source_lock_sha256,spack_lock_path,spack_lock_sha256,status,target,target_contract_sha256,target_policy_sha256,target_registry_sha256`
- `chapar-vlad-builder-handoff/v1`: `build_root,chapar_commit,image_id,image_path,image_sha256,image_size,release_binding,release_binding_sha256,schema,source_lock_sha256,target,validation_root`
- `chapar-vlad-runtime-receipt/v1`: `builder_handoff_sha256,image_path,image_sha256,release_binding_sha256,runtime_preflight_sha256,runtime_receipt_path,schema,smoke_output_sha256,status,target,validator_image_root,validator_root`

The release binding proves the full tuple and release/run identity, every
selection/contract/registry digest, the selection-local effective manifest and
target policy, metadata bytes, and the release-local `spack.lock`. Builder and
runtime receipts then bind immutable handoffs, image bytes, preflight evidence,
and smoke output. Unknown or duplicate keys, non-canonical paths, mutable
inputs, digest drift, or role mismatch fail closed before candidate or final
writes.

The image layer preserves build-time absolute prefixes and injects explicit
roots plus link/run closure. Modules remain opt-in at the registry module
destination. A plan cannot substitute for Enroot import/export or in-image
runtime verification.

Vlad delivery covers four registry targets: `linux-x86_64-generic` and
`linux-aarch64-generic` for portable delivery, plus `linux-x86_64-v4` and
`linux-aarch64-gb300`, which narrow the ISA level and the CUDA architecture list
respectively. A contract selecting any container must declare `install_tree`
under the reserved `/opt/chapar` namespace, and `publication.publish_containers`
must be true before an artifact is produced. `docs/container-injection.md` records
the host-versus-image split the build enforces and the non-interference rules; the
rootfs inventory diff, glibc comparison, in-image unshadowing check, and
`validation/tests/container-smoke.sbatch` all require a real container and have
not run.

## Immutable legacy state

`/resources/chapar/vlad` and `/resources/chapar/hpcsim` are immutable
shadow/canary roots. Do not read them as new desired-state authority and do not
mutate, promote, migrate, clean, or retire them under this work. New contract
paths must not overlap `/resources/chapar`.

## Deferred operator gates

After explicit approval and source-lock completion, a human operator must run
on each matching target platform: contract installation/review, native Spack
concretization, versioned release build, integrity validation, promotion if
permitted, image preflight/import/export, validator receipt, and publisher
receipt. CPU ISA, GB300/CUDA, Slurm/Pyxis/PMIx/Munge, RDMA/network, module
availability, base glibc, filesystem atomicity, and final `.sqsh` payload checks
remain unverified.

Offline contract and selection behavior is verified; target-platform behavior not validated.
None of the deferred platform commands has been run or is
approved by this document.
