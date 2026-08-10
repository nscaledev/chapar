"""`chapar image` subcommands: build, preflight, resolve, publish, verify-release."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def register(subparsers: argparse._SubParsersAction[argparse.ArgumentParser]) -> None:
    image = subparsers.add_parser(
        "image", help="container-image pipeline: plan/build injected images, host preflight, publication"
    )
    commands = image.add_subparsers(dest="command", metavar="COMMAND", required=True)

    build = commands.add_parser(
        "build",
        help="layer a verified release into a digest-locked base image and export a .sqsh",
        description="Layer a promoted Chapar release into the digest-pinned base image selected from "
        "containers.json and export an Enroot squashfs for Pyxis. --plan-only is pure reads and is the "
        "only mode that is useful on a workstation.",
    )
    build.add_argument("--base", required=True, help="container id from containers.json (e.g. nvidia-vlad)")
    build.add_argument("--target", required=True, help="target id from targets.json (e.g. linux-x86_64-v4)")
    build.add_argument("--release-dir", required=True, help="immutable release directory to inject")
    build.add_argument("--image-id", required=True, help="short lowercase identifier for this image build")
    build.add_argument("--output-dir", type=Path, help="artifact directory (default: derived from CHAPAR_CONTAINER_OUTPUT_ROOT)")
    build.add_argument("--enroot-build-root", type=Path, help="enroot data/cache/temp/runtime root (default: under the output dir)")
    build.add_argument("--keep-container", action="store_true", help="keep the working enroot container for debugging")
    build.add_argument("--plan-only", action="store_true", help="print the resolved plan without importing or writing anything")
    build.add_argument("--registry-dir", type=Path, help="registry directory (default: containers/images)")
    build.add_argument("--force", action="store_true", help="build even if the release delivery policy omits container")
    build.set_defaults(handler=_run_build)

    preflight = commands.add_parser(
        "preflight",
        help="fail-closed host checks for the build, runtime, or publisher role",
    )
    preflight.add_argument("--mode", required=True, choices=("build", "runtime", "publisher"))
    preflight.add_argument("--release-dir", help="release directory supplying identity (default: site-settings environment)")
    preflight.add_argument("--registry-dir", type=Path, help="registry directory (default: containers/images)")
    preflight.add_argument("--image-id", required=True, help="image build identifier")
    preflight.add_argument("--sha256", help="sealed candidate digest (required in runtime/publisher mode)")
    preflight.add_argument("--base", help="container id (default: $CHAPAR_CONTAINER_BASE)")
    preflight.add_argument("--target", help="target id (default: release identity or $CHAPAR_TARGET)")
    preflight.add_argument("--plan-only", action="store_true", help="print the resolved plan without probing the host")
    preflight.set_defaults(handler=_run_preflight)

    resolve = commands.add_parser(
        "resolve", help="resolve one explicitly selected container/software-set/target tuple"
    )
    resolve.add_argument("--registry-dir", type=Path, help="registry directory (default: containers/images)")
    resolve.add_argument("--targets", type=Path, help="targets.json override")
    resolve.add_argument("--containers", type=Path, help="containers.json override")
    resolve.add_argument("--sources", type=Path, help="sources-lock.json override")
    resolve.add_argument("--container", required=True)
    resolve.add_argument("--software-set", required=True)
    resolve.add_argument("--target", required=True)
    resolve.set_defaults(handler=_run_resolve)

    publish = commands.add_parser(
        "publish", help="hard-link publication of a validated .sqsh into the durable image root"
    )
    publish.add_argument("--source")
    publish.add_argument("--destination-directory")
    publish.add_argument("--destination-name")
    publish.add_argument("--expected-sha256")
    publish.add_argument("--expected-size", type=int)
    publish.add_argument("--self-test", action="store_true")
    publish.set_defaults(handler=_run_publish)

    verify = commands.add_parser(
        "verify-release", help="verify a release directory's digests, identity, and target facts"
    )
    verify.add_argument("--release-dir", required=True, type=Path)
    verify.add_argument("--targets", type=Path, help="targets.json override")
    verify.set_defaults(handler=_run_verify_release)


def _run_build(arguments: argparse.Namespace) -> int:
    from chapar.image.build import run_build

    return run_build(arguments)


def _run_preflight(arguments: argparse.Namespace) -> int:
    from chapar.image.preflight import run_preflight

    return run_preflight(arguments)


def _run_resolve(arguments: argparse.Namespace) -> int:
    from chapar.image.registry import (
        default_registry_dir,
        parse_containers,
        parse_sources,
        parse_targets,
        resolve,
        validate_oci_chains,
    )

    registry_dir = Path(arguments.registry_dir) if arguments.registry_dir else default_registry_dir()
    targets_path = arguments.targets if arguments.targets else registry_dir / "targets.json"
    containers_path = arguments.containers if arguments.containers else registry_dir / "containers.json"
    sources_path = arguments.sources if arguments.sources else registry_dir / "sources-lock.json"
    targets = parse_targets(targets_path)
    sources = parse_sources(sources_path)
    containers = parse_containers(containers_path, targets, sources)
    validate_oci_chains(sources, targets)
    print(json.dumps(resolve(arguments.container, arguments.software_set, arguments.target, targets, containers, sources), indent=2, sort_keys=True))
    return 0


def _run_publish(arguments: argparse.Namespace) -> int:
    from chapar.image.publish import run_publish

    return run_publish(arguments)


def _run_verify_release(arguments: argparse.Namespace) -> int:
    from chapar.common.release import verify_release

    release = verify_release(Path(arguments.release_dir).resolve(), targets_registry=arguments.targets)
    print(
        json.dumps(
            {
                "software_set": release.software_set,
                "target": release.target,
                "release_id": release.release_id,
                "run_id": release.run_id,
                "release_lock_sha256": release.lock_sha256,
                "deliver": list(release.deliver),
                "module_systems": list(release.module_systems),
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0
