"""`chapar image preflight` semantics, ported from preflight-test.sh.

Every failure case asserts fail-closed behavior: non-zero exit (77 only for a
declared-but-absent runtime feature) and no privileged capability probe -- the
tool stubs write a side-effect marker whenever they are invoked for anything
but a version query.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Iterator
from dataclasses import dataclass, field
from pathlib import Path

import pytest

from tests.conftest import REPO_ROOT

TARGET = "linux-x86_64-generic"
IMAGE_ID = "fixture-image"
IMAGE_SHA = "a" * 64
STUB_TOOLS = (
    "docker",
    "docker-buildx",
    "buildctl",
    "enroot",
    "mksquashfs",
    "unsquashfs",
    "skopeo",
    "syft",
    "jq",
    "zstd",
    "python3",
    "sha256sum",
    "srun",
    "getfacl",
    "lscpu",
    "nvidia-smi",
)
TOOL_BINARIES = {
    "docker-buildx": ["docker", "docker-buildx"],
    "buildkit": ["buildctl"],
    "enroot": ["enroot"],
    "squashfs-tools": ["mksquashfs", "unsquashfs"],
    "zstd": ["zstd"],
    "syft": ["syft"],
    "jq": ["jq"],
    "skopeo": ["skopeo"],
}
TOOL_SOURCES = {
    "docker-buildx": "https://github.com/docker/buildx/releases/download/1.0.0/docker-buildx-1.0.0",
    "buildkit": "https://github.com/moby/buildkit/releases/download/1.0.0/buildkit-1.0.0",
    "enroot": "https://github.com/NVIDIA/enroot/releases/download/1.0.0/enroot-1.0.0",
    "squashfs-tools": "https://snapshot.ubuntu.com/ubuntu/20260731T000000Z/pool/squashfs-tools_1.0.0_amd64.deb",
    "zstd": "https://snapshot.ubuntu.com/ubuntu/20260731T000000Z/pool/zstd_1.0.0_amd64.deb",
    "syft": "https://github.com/anchore/syft/releases/download/1.0.0/syft-1.0.0",
    "jq": "https://github.com/jqlang/jq/releases/download/1.0.0/jq-1.0.0",
    "skopeo": "https://github.com/containers/skopeo/releases/download/1.0.0/skopeo-1.0.0",
}


@dataclass
class Preflight:
    """One isolated preflight fixture: test root, stubs, registries, site env."""

    root: Path
    env: dict[str, str] = field(default_factory=dict)

    @property
    def tools(self) -> Path:
        return self.root / "tools"

    @property
    def marker(self) -> Path:
        return self.root / "privileged-side-effect"

    @property
    def source_lock(self) -> Path:
        return self.root / "sources-lock.json"

    @property
    def site_file(self) -> Path:
        return self.root / "chapar-site.env"

    @property
    def image_root(self) -> Path:
        return self.root / "images" / "hpcsim" / TARGET

    @property
    def validation_root(self) -> Path:
        return self.root / "validation" / "hpcsim" / TARGET

    @property
    def candidate(self) -> Path:
        return self.image_root / "staging" / IMAGE_ID

    def rewrite_lock(self, mutate) -> None:
        document = json.loads(self.source_lock.read_text())
        mutate(document)
        self.source_lock.write_text(json.dumps(document))

    def rewrite_inventory(self, mutate) -> None:
        path = self.root / "inventory.json"
        document = json.loads(path.read_text())
        mutate(document)
        path.write_text(json.dumps(document))

    def rewrite_filesystems(self, mutate) -> None:
        path = self.root / "filesystems.json"
        document = json.loads(path.read_text())
        mutate(document)
        path.write_text(json.dumps(document))

    def run(self, *arguments: str, env_overrides: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        environment = dict(self.env)
        if env_overrides:
            environment.update(env_overrides)
        self.marker.unlink(missing_ok=True)
        return subprocess.run(
            [sys.executable, "-m", "chapar", "image", "preflight", *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=60,
            cwd=REPO_ROOT,
            env=environment,
        )

    def expect_failure(self, *arguments: str, env_overrides: dict[str, str] | None = None) -> str:
        completed = self.run(*arguments, env_overrides=env_overrides)
        assert completed.returncode not in (0, 77), completed.stdout + completed.stderr
        assert not self.marker.exists(), "failure reached a privileged capability probe"
        return completed.stderr


BUILD_ARGS = ("--mode", "build", "--image-id", IMAGE_ID)
RUNTIME_ARGS = ("--mode", "runtime", "--image-id", IMAGE_ID, "--sha256", IMAGE_SHA)
PUBLISHER_ARGS = ("--mode", "publisher", "--image-id", IMAGE_ID, "--sha256", IMAGE_SHA)


def _complete_lock(tools: Path) -> dict:
    source = json.loads((REPO_ROOT / "containers/images/sources-lock.json").read_text())
    source["status"] = "complete"
    source["unresolved"] = []
    snapshot = "https://snapshot.ubuntu.com/ubuntu/20260731T000000Z"
    fingerprint = "A" * 40
    source["verified"]["nvidia_hpc_benchmarks_oci"] = {
        "image": "nvcr.io/nvidia/hpc-benchmarks",
        "tag": "26.02",
        "index_digest": "sha256:" + "1" * 64,
        "platforms": {
            "linux-x86_64-generic": {"oci_platform": "linux/amd64", "descriptor_digest": "sha256:" + "2" * 64, "config_digest": "sha256:" + "3" * 64},
            "linux-x86_64-v4": {"oci_platform": "linux/amd64", "descriptor_digest": "sha256:" + "2" * 64, "config_digest": "sha256:" + "3" * 64},
            "linux-aarch64-generic": {"oci_platform": "linux/arm64", "descriptor_digest": "sha256:" + "4" * 64, "config_digest": "sha256:" + "5" * 64},
            "linux-aarch64-gb300": {"oci_platform": "linux/arm64", "descriptor_digest": "sha256:" + "4" * 64, "config_digest": "sha256:" + "5" * 64},
        },
        "resolved_on": "2026-07-31",
    }
    source["verified"]["ubuntu_snapshot"] = {
        "release": "24.04",
        "snapshot_url": snapshot + "/",
        "pockets": [
            {
                "id": "noble",
                "inrelease_url": snapshot + "/dists/noble/InRelease",
                "inrelease_sha256": "6" * 64,
                "package_indexes": [
                    {"architecture": "amd64", "url": snapshot + "/dists/noble/main/binary-amd64/Packages.xz", "sha256": "7" * 64},
                    {"architecture": "arm64", "url": snapshot + "/dists/noble/main/binary-arm64/Packages.xz", "sha256": "8" * 64},
                ],
            }
        ],
        "archive_key_fingerprint": fingerprint,
        "resolved_on": "2026-07-31",
    }
    source["verified"]["ubuntu_archive_key"] = {
        "fingerprint": fingerprint,
        "source_url": "https://keyserver.ubuntu.com/pks/lookup?op=get&search=" + fingerprint,
        "key_sha256": "e" * 64,
        "resolved_on": "2026-07-31",
    }

    def packages(prefix: str) -> list[dict]:
        return [
            {
                "name": prefix,
                "version": "1.0.0-1",
                "architecture": architecture,
                "url": snapshot + f"/pool/{prefix}_1.0.0-1_{architecture}.deb",
                "sha256": digest * 64,
            }
            for architecture, digest in (("amd64", "9"), ("arm64", "a"))
        ]

    source["verified"]["ubuntu_builder_packages"] = packages("fixture-builder")
    source["verified"]["ubuntu_final_packages"] = packages("fixture-final")
    source["verified"]["builder_tools"] = [
        {
            "id": identity,
            "version": "1.0.0",
            "source_url": TOOL_SOURCES[identity],
            "release_sha256": "b" * 64,
            "assets": {
                arch: {
                    "url": TOOL_SOURCES[identity] + f"-{arch}",
                    "sha256": "e" * 64,
                    "binaries": [
                        {"name": name, "sha256": hashlib.sha256((tools / name).read_bytes()).hexdigest()}
                        for name in names
                    ],
                }
                for arch in ("x86_64", "aarch64")
            },
        }
        for identity, names in TOOL_BINARIES.items()
    ]
    source["verified"]["actions_runner_archives"] = [
        {"id": "linux-x64", "architecture": "x64", "version": "2.999.0", "url": "https://github.com/actions/runner/releases/download/v2.999.0/actions-runner-linux-x64-2.999.0.tar.gz", "sha256": "c" * 64},
        {"id": "linux-arm64", "architecture": "arm64", "version": "2.999.0", "url": "https://github.com/actions/runner/releases/download/v2.999.0/actions-runner-linux-arm64-2.999.0.tar.gz", "sha256": "d" * 64},
    ]
    return source


@pytest.fixture
def preflight() -> Iterator[Preflight]:
    # Not under pytest's tmp_path: the site-settings parent-chain check walks to
    # / and refuses the world-writable /tmp, exactly as it must on a real host.
    # A tree under $HOME (owner-only at every level we create) is representative
    # of an installed settings file.
    base = Path.home() / ".cache" / "chapar-image-preflight-tests"
    base.mkdir(parents=True, exist_ok=True)
    base.chmod(0o700)
    work = Path(tempfile.mkdtemp(dir=base))
    work.chmod(0o700)
    root = work / "fixture"
    root.mkdir()
    fixture = Preflight(root)
    fixture.tools.mkdir()
    for tool in STUB_TOOLS:
        stub = fixture.tools / tool
        stub.write_text(
            "#!/usr/bin/env bash\n"
            'case "$*" in *version*|*-version*|*--version*) printf "1.0.0\\n"; exit 0 ;; esac\n'
            f'printf "invoked" >"{fixture.marker}"\n'
            "exit 0\n"
        )
        stub.chmod(0o755)
    fixture.source_lock.write_text(json.dumps(_complete_lock(fixture.tools)))
    for name in ("targets.json", "containers.json"):
        (root / name).write_bytes((REPO_ROOT / "containers/images" / name).read_bytes())
    (root / "boot-id").write_text("fixture-boot-id\n")
    inventory = {
        "partitions": [{"partition": "x86v1", "constraints": ["physical_v1"], "available": True}],
        "runtime": {
            "physical_x86_64_v1": True,
            "pmix": True,
            "pyxis": True,
            "munge": True,
            "shared_image": True,
            "pmix_plugins": ["pmix_v4"],
            "pyxis_flags": ["--container-image", "--container-readonly"],
            "munge_domain": "fixture-security-domain",
            "network_expectation": "fixture-network-contract-met",
            "lscpu": "fixture physical x86-64-v1 node",
            "cpuid_isa_level": "x86-64-v1",
            "elf_isa_level": "x86-64-v1",
        },
    }
    (root / "inventory.json").write_text(json.dumps(inventory))
    filesystems = {
        "paths": {
            str(root / "images"): {"fstype": "nfs4", "device": "0:44", "acl": ["user::rwx", "group::r-x", "mask::r-x", "other::---"], "fsync_ok": True},
            str(root / "validation"): {"fstype": "nfs4", "device": "0:43", "acl": ["user::rwx", "group::r-x", "mask::r-x", "other::---"], "fsync_ok": True},
        }
    }
    (root / "filesystems.json").write_text(json.dumps(filesystems))
    fixture.site_file.write_text("CHAPAR_SOFTWARE_SET=hpcsim\n")
    fixture.site_file.chmod(0o600)
    fixture.candidate.mkdir(parents=True)
    root.chmod(0o700)
    # Build role: writable candidate, non-writable durable image root.
    fixture.image_root.chmod(0o555)
    fixture.env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(Path.home()),
        "VLAD_PREFLIGHT_TEST_MODE": "1",
        "VLAD_PREFLIGHT_TEST_ROOT": str(root),
        "VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER": str(fixture.marker),
        "VLAD_PREFLIGHT_TEST_CONTRACT_UID": str(os.getuid()),
        "VLAD_PREFLIGHT_TEST_SOURCES_LOCK": str(fixture.source_lock),
        "VLAD_PREFLIGHT_TEST_TARGETS": str(root / "targets.json"),
        "VLAD_PREFLIGHT_TEST_CONTAINERS": str(root / "containers.json"),
        "VLAD_PREFLIGHT_TEST_UNAME_M": "x86_64",
        "VLAD_PREFLIGHT_TEST_BOOT_ID": str(root / "boot-id"),
        "VLAD_PREFLIGHT_TEST_INVENTORY": str(root / "inventory.json"),
        "VLAD_PREFLIGHT_TEST_FILESYSTEMS": str(root / "filesystems.json"),
        "VLAD_PREFLIGHT_TEST_TOOL_DIR": str(fixture.tools),
        "VLAD_PREFLIGHT_TEST_FREE_BYTES": str(1024**4),
        "VLAD_IMAGE_MIN_FREE_BYTES": str(1024**2),
        "CHAPAR_SITE_CONFIG": str(fixture.site_file),
        "CHAPAR_SOFTWARE_SET": "hpcsim",
        "CHAPAR_TARGET": TARGET,
        "CHAPAR_CONTAINER_BASE": "ubuntu-hpcsim",
        "CHAPAR_CONTAINER_OUTPUT_ROOT": str(root / "images"),
        "CHAPAR_VALIDATION_ROOT": str(root / "validation"),
        "CHAPAR_SLURM_PARTITION": "x86v1",
        "CHAPAR_SLURM_CONSTRAINT": "physical_v1",
    }
    yield fixture
    # The fixture chmods roots to 0555 for the non-writable checks; restore
    # owner write so the tree can be removed.
    subprocess.run(["chmod", "-R", "u+rwX", str(work)], check=False)
    shutil.rmtree(work, ignore_errors=True)


def test_build_pass_emits_evidence(preflight: Preflight) -> None:
    completed = preflight.run(*BUILD_ARGS)
    assert completed.returncode == 0, completed.stderr
    assert not preflight.marker.exists(), "successful preflight invoked a privileged tool stub"
    evidence = json.loads(completed.stdout)
    assert evidence["status"] == "pass"
    assert evidence["mode"] == "build"
    assert evidence["software_set"] == "hpcsim"
    assert evidence["target"] == TARGET
    assert evidence["site_settings_sha256"] == hashlib.sha256(preflight.site_file.read_bytes()).hexdigest()
    assert evidence["capabilities"]["candidate_filesystem"] == "nfs4"


def test_plan_only_reports_without_probes(preflight: Preflight) -> None:
    completed = preflight.run(*BUILD_ARGS, "--plan-only")
    assert completed.returncode == 0, completed.stderr
    plan = json.loads(completed.stdout)
    assert plan["software_set"] == "hpcsim"
    assert plan["container"] == "ubuntu-hpcsim"
    assert plan["slurm"] == {"partition": "x86v1", "constraint": "physical_v1"}


def test_missing_pinned_tool_fails(preflight: Preflight) -> None:
    (preflight.tools / "syft").unlink()
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "syft" in stderr


def test_pinned_tool_checksum_mismatch_fails(preflight: Preflight) -> None:
    with (preflight.tools / "syft").open("a") as stream:
        stream.write("# checksum corruption\n")
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "checksum mismatch" in stderr


def test_pinned_tool_version_mismatch_fails(preflight: Preflight) -> None:
    stub = preflight.tools / "enroot"
    stub.write_text('#!/usr/bin/env bash\nprintf "9.9.9\\n"\n')
    stub.chmod(0o755)
    digest = hashlib.sha256(stub.read_bytes()).hexdigest()

    def repin(lock: dict) -> None:
        entry = next(item for item in lock["verified"]["builder_tools"] if item["id"] == "enroot")
        for asset in entry["assets"].values():
            asset["binaries"][0]["sha256"] = digest

    preflight.rewrite_lock(repin)
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "version mismatch" in stderr


def test_insufficient_free_space_fails(preflight: Preflight) -> None:
    stderr = preflight.expect_failure(*BUILD_ARGS, env_overrides={"VLAD_PREFLIGHT_TEST_FREE_BYTES": "1"})
    assert "insufficient free space" in stderr


def test_non_nfs_candidate_fails(preflight: Preflight) -> None:
    preflight.rewrite_filesystems(lambda doc: doc["paths"][str(preflight.root / "images")].update(fstype="apfs"))
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "not on NFS" in stderr


def test_blocked_lock_fails(preflight: Preflight) -> None:
    preflight.rewrite_lock(lambda lock: lock.update(status="blocked"))
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "blocked or incomplete" in stderr


def test_weakened_required_categories_fail(preflight: Preflight) -> None:
    preflight.rewrite_lock(lambda lock: lock["contract"].update(required_categories=["spack_repositories", "github_actions"]))
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "fixed closed set" in stderr


def test_missing_fixed_category_fails(preflight: Preflight) -> None:
    preflight.rewrite_lock(lambda lock: lock["verified"].pop("ubuntu_final_packages"))
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "fixed categories" in stderr


def test_malformed_category_checksum_fails(preflight: Preflight) -> None:
    preflight.rewrite_lock(lambda lock: lock["verified"]["ubuntu_builder_packages"][0].update(sha256="not-a-checksum"))
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "SHA-256" in stderr


def test_floating_source_ref_fails(preflight: Preflight) -> None:
    preflight.rewrite_lock(lambda lock: lock["verified"]["spack_repositories"][0].update(commit="develop"))
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "exact 40-hex commit" in stderr


def test_native_architecture_mismatch_fails(preflight: Preflight) -> None:
    stderr = preflight.expect_failure(*BUILD_ARGS, env_overrides={"VLAD_PREFLIGHT_TEST_UNAME_M": "aarch64"})
    assert "native architecture mismatch" in stderr


def test_symlinked_site_settings_fail(preflight: Preflight) -> None:
    real = preflight.site_file.with_suffix(".real")
    preflight.site_file.rename(real)
    preflight.site_file.symlink_to(real)
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "symlink" in stderr


def test_writable_site_settings_fail(preflight: Preflight) -> None:
    preflight.site_file.chmod(0o666)
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "0644 or stricter" in stderr


def test_foreign_owned_site_settings_fail(preflight: Preflight) -> None:
    expected_uid = "0" if os.getuid() != 0 else "1"
    stderr = preflight.expect_failure(*BUILD_ARGS, env_overrides={"VLAD_PREFLIGHT_TEST_CONTRACT_UID": expected_uid})
    assert "root-owned" in stderr


def test_test_root_escape_fails(preflight: Preflight) -> None:
    outside = preflight.root.parent / "outside-inventory.json"
    outside.write_text((preflight.root / "inventory.json").read_text())
    stderr = preflight.expect_failure(*BUILD_ARGS, env_overrides={"VLAD_PREFLIGHT_TEST_INVENTORY": str(outside)})
    assert "escapes the protected test root" in stderr


def test_marker_escape_fails(preflight: Preflight) -> None:
    outside = preflight.root.parent / "outside-marker"
    preflight.expect_failure(*BUILD_ARGS, env_overrides={"VLAD_PREFLIGHT_TEST_SIDE_EFFECT_MARKER": str(outside)})
    assert not outside.exists()


def test_symlinked_test_root_fails(preflight: Preflight) -> None:
    link = preflight.root.parent / "fixture-link"
    link.symlink_to(preflight.root)
    preflight.expect_failure(*BUILD_ARGS, env_overrides={"VLAD_PREFLIGHT_TEST_ROOT": str(link)})


def test_permissive_test_root_fails(preflight: Preflight) -> None:
    preflight.root.chmod(0o755)
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "owner-only" in stderr


def test_unknown_test_override_fails(preflight: Preflight) -> None:
    stderr = preflight.expect_failure(*BUILD_ARGS, env_overrides={"VLAD_PREFLIGHT_TEST_BOGUS": "1"})
    assert "unknown preflight test override" in stderr


def test_public_output_root_fails_in_test_mode(preflight: Preflight) -> None:
    stderr = preflight.expect_failure(
        *BUILD_ARGS, env_overrides={"CHAPAR_CONTAINER_OUTPUT_ROOT": "/resources/chapar/vlad/image-candidates"}
    )
    assert "escapes the protected test root" in stderr


def test_absent_slurm_pair_fails(preflight: Preflight) -> None:
    preflight.rewrite_inventory(lambda doc: doc["partitions"][0].update(constraints=["wrong"]))
    stderr = preflight.expect_failure(*BUILD_ARGS)
    assert "partition/constraint" in stderr


def test_release_dir_identity_binds_preflight(preflight: Preflight) -> None:
    from tests.conftest import make_release_dir

    release_dir = make_release_dir(
        preflight.root / "releases", software_set="hpcsim", target=TARGET, release_id="rel-pf"
    )
    completed = preflight.run(*BUILD_ARGS, "--release-dir", str(release_dir), "--plan-only")
    assert completed.returncode == 0, completed.stderr
    assert json.loads(completed.stdout)["release_id"] == "rel-pf"
    mismatched = preflight.expect_failure(
        *BUILD_ARGS, "--release-dir", str(release_dir), "--target", "linux-x86_64-v4", "--plan-only"
    )
    assert "does not match the release target" in mismatched


def _arrange_runtime(preflight: Preflight) -> None:
    sealed = preflight.candidate / IMAGE_SHA
    sealed.mkdir(parents=True, exist_ok=True)
    sealed.chmod(0o555)
    receipt = preflight.validation_root / IMAGE_ID / IMAGE_SHA
    receipt.mkdir(parents=True, exist_ok=True)
    receipt.chmod(0o750)


def test_runtime_pass(preflight: Preflight) -> None:
    _arrange_runtime(preflight)
    completed = preflight.run(*RUNTIME_ARGS)
    assert completed.returncode == 0, completed.stderr
    evidence = json.loads(completed.stdout)
    assert evidence["mode"] == "runtime"
    assert evidence["capabilities"]["runtime_inventory"]["cpuid_isa_level"] == "x86-64-v1"


def test_runtime_absent_declared_feature_skips_77(preflight: Preflight) -> None:
    _arrange_runtime(preflight)
    preflight.rewrite_inventory(lambda doc: doc["runtime"].update(physical_x86_64_v1=False))
    completed = preflight.run(*RUNTIME_ARGS)
    assert completed.returncode == 77, completed.stdout + completed.stderr
    assert not preflight.marker.exists()
    assert "absent declared runtime hardware/features" in completed.stderr


def test_runtime_isa_evidence_required(preflight: Preflight) -> None:
    _arrange_runtime(preflight)
    preflight.rewrite_inventory(lambda doc: doc["runtime"].update(cpuid_isa_level="x86-64-v2"))
    stderr = preflight.expect_failure(*RUNTIME_ARGS)
    assert "x86-64-v1 evidence" in stderr


def _arrange_publisher(preflight: Preflight) -> None:
    _arrange_runtime(preflight)
    receipt = preflight.validation_root / IMAGE_ID / IMAGE_SHA
    receipt.chmod(0o555)
    preflight.image_root.chmod(0o750)
    releases = preflight.image_root / "releases"
    releases.mkdir(exist_ok=True)
    releases.chmod(0o750)


def test_publisher_pass_leaves_no_probe_files(preflight: Preflight) -> None:
    _arrange_publisher(preflight)
    completed = preflight.run(*PUBLISHER_ARGS)
    assert completed.returncode == 0, completed.stderr
    evidence = json.loads(completed.stdout)
    assert evidence["mode"] == "publisher"
    leftovers = list((preflight.image_root / "releases").glob(".preflight-fsync.*"))
    assert leftovers == []


def test_publisher_group_writable_releases_fail(preflight: Preflight) -> None:
    _arrange_publisher(preflight)
    (preflight.image_root / "releases").chmod(0o770)
    stderr = preflight.expect_failure(*PUBLISHER_ARGS)
    assert "unsafe mode" in stderr


def test_publisher_named_acl_write_fails(preflight: Preflight) -> None:
    _arrange_publisher(preflight)
    preflight.rewrite_filesystems(
        lambda doc: doc["paths"][str(preflight.root / "images")].update(
            acl=["user::rwx", "group::r-x", "group:untrusted:rwx", "mask::rwx", "other::---"]
        )
    )
    stderr = preflight.expect_failure(*PUBLISHER_ARGS)
    assert "non-owner write authority" in stderr


def test_publisher_default_acl_write_fails(preflight: Preflight) -> None:
    _arrange_publisher(preflight)
    preflight.rewrite_filesystems(
        lambda doc: doc["paths"][str(preflight.root / "images")].update(
            acl=["user::rwx", "group::r-x", "mask::r-x", "other::---", "default:group:untrusted:rwx"]
        )
    )
    stderr = preflight.expect_failure(*PUBLISHER_ARGS)
    assert "default ACL grants write authority" in stderr


def test_publisher_malformed_acl_fails(preflight: Preflight) -> None:
    _arrange_publisher(preflight)
    preflight.rewrite_filesystems(
        lambda doc: doc["paths"][str(preflight.root / "images")].update(
            acl=["user::rwx", "group::", "mask::r-x", "other::---"]
        )
    )
    stderr = preflight.expect_failure(*PUBLISHER_ARGS)
    assert "ACL" in stderr


def test_publisher_fsync_fixture_failure_fails(preflight: Preflight) -> None:
    _arrange_publisher(preflight)
    preflight.rewrite_filesystems(lambda doc: doc["paths"][str(preflight.root / "images")].update(fsync_ok=False))
    stderr = preflight.expect_failure(*PUBLISHER_ARGS)
    assert "fsync" in stderr


def test_publisher_fsync_cleanup_after_rename_failure(preflight: Preflight) -> None:
    _arrange_publisher(preflight)
    preflight.rewrite_filesystems(lambda doc: doc["paths"][str(preflight.root / "images")].update(fsync_fail_at="after-rename"))
    preflight.expect_failure(*PUBLISHER_ARGS)
    leftovers = list((preflight.image_root / "releases").glob(".preflight-fsync.*"))
    assert leftovers == []
