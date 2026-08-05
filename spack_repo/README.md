# spack_repo/chapar_plus

`spack_repo/chapar_plus` is Chapar's example Spack repository for industrial simulation applications. It shows how to package applications that are built from source and applications that are available only as vendor binaries.

## Source-Available Example

`chapar-source-example` is the pattern for an internal or vendor source tarball:

```bash
spack spec chapar-source-example+mpi~cuda
```

In a real package, replace the example URL and checksum with the real source release, then map the package variants to the application's build-system flags. Add the package spec to `envs/<name>/spack.yaml`, then build it with `envs/<name>/release.sh build <id>`. This is the pattern for source-available solvers that build with CMake, Make, or a vendor build script.

## Binary-Only Example

`chapar-binary-only-example` is the pattern for applications such as STAR-CCM+, LS-DYNA, or Abaqus when source is not available:

```bash
export CHAPAR_BINARY_ONLY_EXAMPLE_ROOT=/opt/vendor/abaqus/2024
spack spec chapar-binary-only-example
```

The vendor installer still runs outside Spack. Add the package spec to `envs/<name>/spack.yaml`, then build it with `envs/<name>/release.sh build <id>`. The package copies that installed tree into a Spack prefix and publishes a normal Spack module with paths. Product-specific license variables such as `ABAQUSLM_LICENSE_FILE` belong in the package's `setup_run_environment()` method or in `modules.yaml` when the value differs by site.
