"""`chapar image publish` (the hard-link publication state machine)."""

from __future__ import annotations

import errno
import hashlib
from pathlib import Path

import pytest

from chapar.image.publish import (
    CrashPoint,
    InstallError,
    InstallRequest,
    assert_crash_state,
    install,
    partials,
    run_crash,
    self_test,
)
from tests.conftest import run_chapar


def _source(tmp_path: Path) -> tuple[Path, bytes, str]:
    content = (b"validated-sqsh\n" * 1024) + b"end"
    source = tmp_path / "source.sqsh"
    source.write_bytes(content)
    return source, content, hashlib.sha256(content).hexdigest()


def test_self_test_passes(capsys: pytest.CaptureFixture[str]) -> None:
    """The embedded self-test carries the full case matrix, including the
    real-process crash fixtures; it raises on any failure."""
    self_test()
    assert "validated SQSH installer self-test passed" in capsys.readouterr().out


def test_happy_publication(tmp_path: Path) -> None:
    source, content, digest = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    install(InstallRequest(str(source), str(destination), "image.sqsh", digest, len(content)))
    final = destination / "image.sqsh"
    assert final.read_bytes() == content
    assert partials(destination, "image.sqsh") == ()


def test_final_is_never_overwritten(tmp_path: Path) -> None:
    source, content, digest = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    request = InstallRequest(str(source), str(destination), "image.sqsh", digest, len(content))
    install(request)
    with pytest.raises(OSError) as excinfo:
        install(request)
    assert excinfo.value.errno == errno.EEXIST
    assert (destination / "image.sqsh").read_bytes() == content


def test_digest_mismatch_rejected_without_output(tmp_path: Path) -> None:
    source, content, _ = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    with pytest.raises(InstallError):
        install(InstallRequest(str(source), str(destination), "image.sqsh", "0" * 64, len(content)))
    assert not (destination / "image.sqsh").exists()
    assert partials(destination, "image.sqsh") == ()


def test_size_mismatch_rejected(tmp_path: Path) -> None:
    source, content, digest = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    with pytest.raises(InstallError, match="size mismatch"):
        install(InstallRequest(str(source), str(destination), "image.sqsh", digest, len(content) + 1))


def test_symlink_source_rejected(tmp_path: Path) -> None:
    source, content, digest = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    link = tmp_path / "link.sqsh"
    link.symlink_to(source)
    with pytest.raises(OSError):
        install(InstallRequest(str(link), str(destination), "image.sqsh", digest, len(content)))


def test_noncanonical_path_rejected(tmp_path: Path) -> None:
    _, content, digest = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    with pytest.raises(InstallError, match="canonical absolute path"):
        install(InstallRequest(f"{tmp_path}/./source.sqsh", str(destination), "image.sqsh", digest, len(content)))


@pytest.mark.parametrize("point", list(CrashPoint))
def test_crash_states(tmp_path: Path, point: CrashPoint) -> None:
    source, content, digest = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    name = f"crash-{point}.sqsh"
    request = InstallRequest(str(source), str(destination), name, digest, len(content))
    run_crash(request, point)
    assert_crash_state(destination, name, point)


def test_cli_publish_and_self_test(tmp_path: Path) -> None:
    source, content, digest = _source(tmp_path)
    destination = tmp_path / "destination"
    destination.mkdir()
    result = run_chapar(
        "image",
        "publish",
        "--source",
        str(source),
        "--destination-directory",
        str(destination),
        "--destination-name",
        "image.sqsh",
        "--expected-sha256",
        digest,
        "--expected-size",
        str(len(content)),
    )
    assert result.exit_code == 0, result.stderr
    assert "installed" in result.stdout
    assert (destination / "image.sqsh").read_bytes() == content

    mismatch = run_chapar(
        "image",
        "publish",
        "--source",
        str(source),
        "--destination-directory",
        str(destination),
        "--destination-name",
        "other.sqsh",
        "--expected-sha256",
        "0" * 64,
        "--expected-size",
        str(len(content)),
    )
    assert mismatch.exit_code == 2
    assert "SHA-256 mismatch" in mismatch.stderr

    self_test_result = run_chapar("image", "publish", "--self-test", timeout=120)
    assert self_test_result.exit_code == 0, self_test_result.stderr
    assert "self-test passed" in self_test_result.stdout
