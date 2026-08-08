# Future work

- Review and install a real non-secret `datacenters/<id>` desired-state
  snapshot. No active contract exists today.
- Complete every category and per-platform descriptor in
  `containers/images/sources-lock.json`; its global status remains `blocked`.
- With explicit platform approval, validate native concretization and
  selection-bound versioned releases on Ubuntu 24.04 for each registry tuple.
- With separate approval, validate Slurm placement, modules/integrity, GPU,
  RDMA, MPI, NCCL, I/O, Enroot import/export, and `.sqsh` publication.
- Run `validation/tests/container-smoke.sbatch` once a sealed `.sqsh` exists for
  a registry-approved tuple. It is the only test that uses Pyxis, and it produces
  the `pyxis-smoke.txt` that the runtime receipt digests. The rootfs inventory
  diff, the release-versus-base glibc comparison, and the in-image unshadowing
  check in `containers/images/build-image.sh` likewise need a real
  `enroot create` and have not run.
- Decide whether the reserved `/opt/chapar` store namespace is bind-mounted onto
  site storage on each builder. Injection copies store prefixes into the image at
  their identical absolute path, and image planning rejects a symlinked store
  component, so a symlink is not an option.
- Decide CI design before adding any `.github/workflows/` file.
- Evaluate AlmaLinux, CVMFS/Apptainer delivery, and additional architectures
  only through new target-registry facts and reviewed data-center contracts.
- Decide any legacy cache migration or retirement separately. This work grants
  no approval to modify `/resources/chapar/vlad` or
  `/resources/chapar/hpcsim`.

Offline contract and selection behavior is verified; target-platform behavior
not validated.
