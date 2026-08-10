# Future work

Done: the repository is restructured onto the site-settings model — one
catalog, per-machine `etc/chapar-site.env`, immutable releases, and
release-bound consumers.

- Decide CI automation. There is still no `.github/workflows/` file; the
  offline gate (`ci/tests/software-specs-offline-gate.sh`) is runnable by hand
  and is what any future workflow would call.
- Complete `containers/images/sources-lock.json` before the first real image
  build; its global status remains `blocked`. The NVIDIA hpc-benchmarks OCI
  base needs an authenticated fetch to pin its digest, and `ubuntu_base_oci`
  lacks an arm64 platform entry.
- Run the outstanding operator platform gates on Ubuntu 24.04/Slurm:
  - a first `release.sh build` smoke on a builder, including the padded-store
    continuity check (`etc/chapar-install-tree.sh` must reproduce the store's
    existing placeholder depth);
  - a native concretization check of the catalog `when:` conditions on the
    pinned Spack for each software set and registered target;
  - a real image build plus `validation/tests/container-smoke.sbatch` once a
    sealed `.sqsh` exists for an approved tuple;
  - the hardware validation tiers (GPU, RDMA, MPI, NCCL, I/O) on matching
    hardware — offline fixtures prove the evaluators, not the hardware.
- Re-provision runners for the image roles when CI becomes real.
  `register-vlad-image-runner.sh` was deleted with the site-contract
  machinery; any replacement must derive its paths and policy from the site
  settings.
- Exercise lmod delivery. `CHAPAR_MODULE_SYSTEMS="tcl lmod"` is plumbed
  through the site settings and release helper but has never produced a
  consumed lmod tree.

Offline behavior is verified by `make test`; target-platform behavior is not
validated here.
