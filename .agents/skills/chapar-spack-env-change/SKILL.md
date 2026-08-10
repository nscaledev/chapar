---
name: chapar-spack-env-change
description: Change Chapar software root specs, package policy, providers, or variants in the single envs/software catalog. Use for Vlad, HPCSim, or union software-set membership changes.
---

# Chapar software catalog change

`envs/software/spack.yaml` is the only catalog. Roots live in four named
definition lists — `shared_roots`, `vlad_roots`, `hpcsim_roots`, and
`hpcsim_x86_only_roots` — selected by `when:` conditions on
`CHAPAR_SOFTWARE_SET` and `CHAPAR_TARGET`. Never hand-edit those conditions:
`src/chapar/catalog/model.py` pins the exact expected string per list, and
`chapar catalog list` fails on any drift. Move roots between lists instead.

Preserve membership invariants: `vlad` must never gain x86-only roots, and
the `all` set is exactly the union. Target facts (Spack target, CUDA
architectures, LLVM targets) belong only in `containers/images/targets.json`.
Do not edit `spack/`, locks, or add a `spack_repo/` overlay unless asked.

After a change, run `uv run --group dev pytest tests/catalog` and regenerate
the generated catalog README:
`uv run chapar catalog readme --render > envs/software/README.md`
(verify with `--check envs/software/README.md`).

Never run a direct Spack install. Concretizing the changed catalog on a real
builder is an operator gate; offline tests do not prove a solve.
