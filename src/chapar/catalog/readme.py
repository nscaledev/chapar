"""Renderer for the generated envs/software/README.md."""

from __future__ import annotations

from typing import Final

from chapar.catalog.model import Root, source_report, variant_differences

README_BEGIN: Final = "<!-- BEGIN GENERATED CATALOG INVENTORY -->"
README_END: Final = "<!-- END GENERATED CATALOG INVENTORY -->"


def render_readme(roots: tuple[Root, ...]) -> str:
    groups = source_report(roots)
    hpcsim_not_vlad = groups["hpcsim-only"] + groups["architecture-limited"]
    lines = [
        "# Chapar software catalog",
        "",
        "`spack.yaml` is the sole active root-spec and package-policy source. Set membership is selected by `CHAPAR_SOFTWARE_SET` and `CHAPAR_TARGET` conditions on its named root lists, so `spack -e envs/software` composes vlad, hpcsim, or the union directly; `chapar catalog list` renders any composition offline.",
        "",
        "Target-native, Spack, LLVM, and CUDA architecture values belong to the target registry. The only architecture metadata here is the `x86_64` selection condition on the historical Intel roots.",
        "",
        README_BEGIN,
        "## Generated exact inventory",
        "",
        "This section is rendered from `spack.yaml` by `chapar catalog readme`; do not edit it manually.",
        "",
        "The [frozen historical inventory](tests/fixtures/historical-root-inventory.json) preserves 90 exact historical root specs: 42 Vlad, 75 HPCSim, 48 exact HPCSim-not-Vlad entries, and 10 historical variant-difference packages. The target-neutral catalog composes 42 Vlad and 76 HPCSim roots (74 HPCSim roots on ARM), while its logical union has 81 roots because nine CUDA-architecture-only legacy duplicates collapse into shared roots.",
        "",
        "The catalog composition is policy and may deliberately differ from the frozen history it started from. It does so in one place today: `ccache` was historically a Vlad-only root and is now shared, because it is bootstrapped as a build tool for every software set rather than delivered to one of them.",
        "",
        f"- Shared: {len(groups['shared'])}",
        f"- Vlad-only: {len(groups['vlad-only'])}",
        f"- HPCSim-only: {len(groups['hpcsim-only'])}",
        f"- Architecture-limited: {len(groups['architecture-limited'])} (x86_64 only)",
        "",
        "### HPCSim-not-Vlad",
        "",
    ]
    lines.extend(f"- `{specification}`" for specification in hpcsim_not_vlad)
    lines.extend(["", "### Historical variant differences", ""])
    for package, values in variant_differences(roots).items():
        lines.append(f"- `{package}`: Vlad `{values['vlad'][0]}`; HPCSim `{values['hpcsim'][0]}`")
    lines.extend([README_END, ""])
    return "\n".join(lines)
