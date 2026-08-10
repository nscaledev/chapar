# Chapar software catalog

`spack.yaml` is the sole active root-spec and package-policy source. Set membership is selected by `CHAPAR_SOFTWARE_SET` and `CHAPAR_TARGET` conditions on its named root lists, so `spack -e envs/software` composes vlad, hpcsim, or the union directly; `chapar catalog list` renders any composition offline.

Target-native, Spack, LLVM, and CUDA architecture values belong to the target registry. The only architecture metadata here is the `x86_64` selection condition on the historical Intel roots.

<!-- BEGIN GENERATED CATALOG INVENTORY -->
## Generated exact inventory

This section is rendered from `spack.yaml` by `chapar catalog readme`; do not edit it manually.

The [frozen historical inventory](tests/fixtures/historical-root-inventory.json) preserves 90 exact historical root specs: 42 Vlad, 75 HPCSim, 48 exact HPCSim-not-Vlad entries, and 10 historical variant-difference packages. The target-neutral catalog composes 42 Vlad and 76 HPCSim roots (74 HPCSim roots on ARM), while its logical union has 81 roots because nine CUDA-architecture-only legacy duplicates collapse into shared roots.

The catalog composition is policy and may deliberately differ from the frozen history it started from. It does so in one place today: `ccache` was historically a Vlad-only root and is now shared, because it is bootstrapped as a build tool for every software set rather than delivered to one of them.

- Shared: 37
- Vlad-only: 5
- HPCSim-only: 37
- Architecture-limited: 2 (x86_64 only)

### HPCSim-not-Vlad

- `adios2+mpi+fortran+hdf5~libcatalyst~python %gcc ^openmpi@5`
- `cdo+netcdf+hdf5+openmp grib2=eccodes %gcc`
- `cgns+mpi+hdf5+fortran %gcc ^openmpi@5`
- `eccodes+tools+netcdf+png %gcc`
- `exodusii+mpi+fortran %gcc ^openmpi@5`
- `ffmpeg %gcc`
- `fftw+mpi+openmp precision=double,float %gcc`
- `gdb+python ^python@3.12:3.12+tkinter`
- `hdf5+mpi+fortran+hl`
- `hdf5-vol-async %gcc ^openmpi@5`
- `imagemagick@7.1.1-39 ^python@3.12:3.12+optimizations+tkinter`
- `libffi@3.2.1`
- `libffi@3.4.7:`
- `libpressio+mpi+openmp+hdf5+zfp+netcdf~python %gcc ^openmpi@5`
- `nccmp %gcc`
- `nco+openmp %gcc`
- `ncview %gcc`
- `neovim`
- `netcdf-c+mpi+parallel-netcdf`
- `netcdf-fortran`
- `netlib-scalapack`
- `npm@11.2.0`
- `nvshmem+cuda+mpi+ucx+libfabric+nccl ^nccl@2.29.7-1`
- `openblas threads=openmp %gcc`
- `parallel-netcdf`
- `pkgconf`
- `pulseaudio@13.0 %gcc ^fftw~mpi`
- `python@3.10:3.10+optimizations+tkinter`
- `python@3.11:3.11+optimizations+tkinter`
- `seacas@2025-10-14+mpi+adios2~fortran~libcatalyst+cgns+applications~legacy~x11 %gcc@15 ^openmpi@5`
- `silo+mpi+hdf5+fortran~python %gcc ^openmpi@5`
- `sz+openmp+hdf5+netcdf+fortran %gcc`
- `tcl`
- `tk`
- `tmux`
- `valgrind+mpi`
- `zfp+openmp+fortran %gcc`
- `intel-mpi-benchmarks@2021.7`
- `intel-oneapi-mpi@2021.17.0+generic-names+external-libfabric ^libfabric@2+cuda+gdrcopy fabrics=mlx,rxm,verbs ^cuda@13`

### Historical variant differences

- `python`: Vlad `python@3.12:3.12+optimizations+tkinter`; HPCSim `python@3.10:3.10+optimizations+tkinter`
<!-- END GENERATED CATALOG INVENTORY -->
