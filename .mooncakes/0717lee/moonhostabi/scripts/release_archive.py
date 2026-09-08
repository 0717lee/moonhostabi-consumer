from __future__ import annotations

import argparse
from collections.abc import Callable
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import tarfile
import tempfile
import zipfile
import zlib


SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")


def platform_root(version: str, platform: str) -> str:
    if not SEMVER.fullmatch(version):
        raise ValueError("version must be strict MAJOR.MINOR.PATCH")
    if platform not in {"windows", "linux"}:
        raise ValueError("platform must be windows or linux")
    return f"moonhostabi-v{version}-{platform}-x86_64"


def relative_files(platform: str) -> list[str]:
    executable = "moonhostabi.exe" if platform == "windows" else "moonhostabi"
    return sorted(
        [
            "LICENSE",
            "README.md",
            f"bin/{executable}",
            "docs/report-schema.md",
            "docs/validation.md",
            "examples/artifact.wasm",
            "examples/host-abi.lock.json",
            "examples/moonhostabi.contract.json",
        ]
    )


def expected_file_entries(version: str, platform: str) -> list[str]:
    root = platform_root(version, platform)
    return [f"{root}/{name}" for name in relative_files(platform)]


def expected_tar_entries(version: str, platform: str) -> list[str]:
    root = platform_root(version, platform)
    directories = [f"{root}/", f"{root}/bin/", f"{root}/docs/", f"{root}/examples/"]
    return sorted(directories + expected_file_entries(version, platform))


def assert_safe_name(name: str) -> None:
    if not name or "\\" in name or name.startswith("/") or re.match(r"^[A-Za-z]:", name):
        raise ValueError(f"unsafe archive entry path: {name!r}")
    raw_parts = name.rstrip("/").split("/")
    path = PurePosixPath(name.rstrip("/"))
    if (
        path.is_absolute()
        or not raw_parts
        or any(part in {"", ".", ".."} for part in raw_parts)
    ):
        raise ValueError(f"unsafe archive entry path: {name!r}")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def assert_exact_names(actual: list[str], expected: list[str]) -> None:
    seen: set[str] = set()
    folded: set[str] = set()
    for name in actual:
        assert_safe_name(name)
        if name in seen:
            raise ValueError(f"duplicate archive entry: {name}")
        casefolded = name.casefold()
        if casefolded in folded:
            raise ValueError(f"case-fold archive entry collision: {name}")
        seen.add(name)
        folded.add(casefolded)
    if actual != expected:
        raise ValueError(f"archive layout/order mismatch: {actual!r}")


def validate_zip(
    archive_path: Path,
    version: str,
    allow_simulated_metadata: bool,
) -> tuple[list[dict[str, object]], dict[str, bytes]]:
    expected = expected_file_entries(version, "windows")
    records: list[dict[str, object]] = []
    payloads: dict[str, bytes] = {}
    with zipfile.ZipFile(archive_path, "r") as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        assert_exact_names(names, expected)
        for info in infos:
            if info.is_dir():
                raise ValueError(f"directory ZIP entry is not allowed: {info.filename}")
            if info.date_time != (1980, 1, 1, 0, 0, 0):
                raise ValueError(f"noncanonical ZIP timestamp: {info.filename}")
            if info.compress_type != zipfile.ZIP_STORED or info.compress_size != info.file_size:
                raise ValueError(f"compressed ZIP entry is not allowed: {info.filename}")
            if not allow_simulated_metadata and info.external_attr != 0:
                raise ValueError(f"noncanonical ZIP attributes: {info.filename}")
            data = archive.read(info)
            if len(data) != info.file_size:
                raise ValueError(f"ZIP size mismatch: {info.filename}")
            relative = info.filename.split("/", 1)[1]
            payloads[relative] = data
            records.append(
                {
                    "path": info.filename,
                    "sha256": sha256_bytes(data),
                    "size": len(data),
                    "mode": None,
                }
            )
    return records, payloads


def normalized_tar_name(member: tarfile.TarInfo) -> str:
    return member.name.rstrip("/") + ("/" if member.isdir() else "")


def assert_canonical_tar_end(decoded: bytes, members: list[tarfile.TarInfo]) -> None:
    if not members:
        raise ValueError("tar archive must contain members")
    for member in members:
        if (
            member.offset < 0
            or member.offset_data < 0
            or member.size < 0
            or member.offset % 512 != 0
            or member.offset_data % 512 != 0
            or member.offset_data < member.offset + 512
        ):
            raise ValueError("tar member offsets are not canonical 512-byte blocks")
    payload_end = max(member.offset_data + member.size for member in members)
    aligned_payload_end = ((payload_end + 511) // 512) * 512
    if len(decoded) < aligned_payload_end + 1024:
        raise ValueError("tar archive must end with two complete zero blocks")
    if any(decoded[payload_end:aligned_payload_end]):
        raise ValueError("tar file payload padding must be zero")
    end_blocks = decoded[aligned_payload_end:]
    if len(end_blocks) % 512 != 0 or any(end_blocks):
        raise ValueError("tar bytes after payload must be zero 512-byte blocks")
    if len(end_blocks) < 1024:
        raise ValueError("tar archive must contain two zero end blocks")


def read_canonical_gzip(archive_path: Path) -> bytes:
    encoded = archive_path.read_bytes()
    canonical_header = bytes.fromhex("1f8b0800000000000203")
    if len(encoded) < 18 or encoded[:10] != canonical_header:
        raise ValueError("gzip header must be canonical gzip -n -9 on Linux")
    try:
        inflater = zlib.decompressobj(wbits=31)
        decoded = inflater.decompress(encoded) + inflater.flush()
    except zlib.error as error:
        raise ValueError(f"invalid gzip stream: {error}") from error
    if not inflater.eof or inflater.unconsumed_tail or inflater.unused_data:
        raise ValueError("gzip must contain exactly one member with no trailing data")
    return decoded


def validate_tar(archive_path: Path, version: str) -> tuple[list[dict[str, object]], dict[str, bytes]]:
    decoded = read_canonical_gzip(archive_path)
    expected = expected_tar_entries(version, "linux")
    records: list[dict[str, object]] = []
    payloads: dict[str, bytes] = {}
    with tarfile.open(fileobj=io.BytesIO(decoded), mode="r:") as archive:
        members = archive.getmembers()
        assert_canonical_tar_end(decoded, members)
        names = [normalized_tar_name(member) for member in members]
        assert_exact_names(names, expected)
        root = platform_root(version, "linux")
        for member, name in zip(members, names, strict=True):
            if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                raise ValueError(f"non-regular tar entry is not allowed: {name}")
            if not (member.isdir() or member.isreg()):
                raise ValueError(f"unsupported tar entry type: {name}")
            if member.mtime != 0 or member.uid != 0 or member.gid != 0:
                raise ValueError(f"noncanonical tar ownership/time metadata: {name}")
            if member.uname != "root" or member.gname != "root":
                raise ValueError(f"noncanonical tar owner names: {name}")
            expected_mode = 0o755 if member.isdir() or name == f"{root}/bin/moonhostabi" else 0o644
            if stat.S_IMODE(member.mode) != expected_mode:
                raise ValueError(f"noncanonical tar mode for {name}: {oct(member.mode)}")
            if member.isdir():
                continue
            extracted = archive.extractfile(member)
            if extracted is None:
                raise ValueError(f"tar file payload is unreadable: {name}")
            data = extracted.read()
            relative = name.split("/", 1)[1]
            payloads[relative] = data
            records.append(
                {
                    "path": name,
                    "sha256": sha256_bytes(data),
                    "size": len(data),
                    "mode": format(expected_mode, "04o"),
                }
            )
    return records, payloads


def validate_archive(
    archive_path: Path,
    version: str,
    platform: str,
    allow_simulated_metadata: bool = False,
) -> tuple[list[dict[str, object]], dict[str, bytes]]:
    if not archive_path.is_file() or archive_path.is_symlink():
        raise ValueError("archive must be a regular non-symlink file")
    if platform == "windows":
        return validate_zip(archive_path, version, allow_simulated_metadata)
    if allow_simulated_metadata:
        raise ValueError("simulated metadata relaxation is only valid for ZIP fixtures")
    return validate_tar(archive_path, version)


def extract_payloads(destination: Path, root: str, payloads: dict[str, bytes], platform: str) -> Path:
    if destination.exists() or destination.is_symlink():
        raise ValueError("extraction destination must not exist")
    package_root = destination / root
    package_root.mkdir(parents=True)
    for relative, data in payloads.items():
        target = package_root.joinpath(*PurePosixPath(relative).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
        if platform == "linux":
            mode = 0o755 if relative == "bin/moonhostabi" else 0o644
            target.chmod(mode)
    return package_root


def source_bytes(source_root: Path, target_platform: str) -> dict[str, bytes]:
    if not source_root.is_dir() or source_root.is_symlink():
        raise ValueError("mock source root must be a regular directory")
    source_bins = list((source_root / "bin").glob("moonhostabi*"))
    if len(source_bins) != 1 or not source_bins[0].is_file() or source_bins[0].is_symlink():
        raise ValueError("mock source root must contain exactly one regular CLI binary")
    result: dict[str, bytes] = {}
    for relative in relative_files(target_platform):
        if relative.startswith("bin/"):
            source = source_bins[0]
        else:
            source = source_root.joinpath(*PurePosixPath(relative).parts)
        if not source.is_file() or source.is_symlink():
            raise ValueError(f"missing regular mock source payload: {relative}")
        result[relative] = source.read_bytes()
    return result


def create_mock_zip(path: Path, version: str, payloads: dict[str, bytes]) -> None:
    root = platform_root(version, "windows")
    with zipfile.ZipFile(path, "x", compression=zipfile.ZIP_STORED) as archive:
        for relative in relative_files("windows"):
            info = zipfile.ZipInfo(f"{root}/{relative}", (1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED
            info.create_system = 0
            info.external_attr = 0x20
            archive.writestr(info, payloads[relative])


def tar_info(name: str, mode: int, is_directory: bool) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name.rstrip("/") + ("/" if is_directory else ""))
    info.type = tarfile.DIRTYPE if is_directory else tarfile.REGTYPE
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "root"
    info.mtime = 0
    return info


def write_canonical_gzip(path: Path, payload: bytes) -> None:
    compressor = zlib.compressobj(level=9, wbits=-zlib.MAX_WBITS)
    compressed = compressor.compress(payload) + compressor.flush()
    trailer = struct.pack("<II", zlib.crc32(payload) & 0xFFFFFFFF, len(payload) & 0xFFFFFFFF)
    with path.open("xb") as stream:
        stream.write(bytes.fromhex("1f8b0800000000000203"))
        stream.write(compressed)
        stream.write(trailer)


def create_mock_tar(path: Path, version: str, payloads: dict[str, bytes]) -> None:
    root = platform_root(version, "linux")
    entries: list[tuple[str, bytes | None, int]] = [
        (f"{root}/", None, 0o755),
        *[(f"{root}/{relative}", data, 0o755 if relative == "bin/moonhostabi" else 0o644) for relative, data in payloads.items()],
        (f"{root}/bin/", None, 0o755),
        (f"{root}/docs/", None, 0o755),
        (f"{root}/examples/", None, 0o755),
    ]
    entries.sort(key=lambda entry: entry[0])
    encoded_tar = io.BytesIO()
    with tarfile.open(fileobj=encoded_tar, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for name, data, mode in entries:
            info = tar_info(name, mode, data is None)
            if data is None:
                archive.addfile(info)
            else:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
    write_canonical_gzip(path, encoded_tar.getvalue())


def create_mock(archive_path: Path, source_root: Path, version: str, platform: str) -> None:
    if archive_path.exists() or archive_path.is_symlink():
        raise ValueError("mock archive output already exists")
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    payloads = source_bytes(source_root, platform)
    if platform == "windows":
        create_mock_zip(archive_path, version, payloads)
    else:
        create_mock_tar(archive_path, version, payloads)


def append_tar_trailing(archive_path: Path, output_path: Path) -> None:
    if output_path.exists() or output_path.is_symlink():
        raise ValueError("tar mutation output already exists")
    decoded = read_canonical_gzip(archive_path)
    write_canonical_gzip(output_path, decoded + b"EVIL")


def expect_rejected(callback: Callable[[], object], label: str) -> None:
    try:
        callback()
    except (OSError, ValueError, tarfile.TarError, zipfile.BadZipFile):
        return
    raise AssertionError(f"release archive negative self-test passed: {label}")


def create_bad_tar(path: Path, kind: str | None) -> None:
    version = "0.1.1"
    root = platform_root(version, "linux")
    target = f"{root}/README.md"
    encoded_tar = io.BytesIO()
    with tarfile.open(fileobj=encoded_tar, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for name in expected_tar_entries(version, "linux"):
            is_directory = name.endswith("/")
            mode = 0o755 if is_directory or name == f"{root}/bin/moonhostabi" else 0o644
            info = tar_info(name, mode, is_directory)
            data = None if is_directory else b"x"
            if name == target and kind is not None:
                data = None
                if kind == "symlink":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "/etc/passwd"
                elif kind == "hardlink":
                    info.type = tarfile.LNKTYPE
                    info.linkname = f"{root}/LICENSE"
                elif kind == "device":
                    info.type = tarfile.CHRTYPE
                    info.devmajor = 1
                    info.devminor = 3
                elif kind == "fifo":
                    info.type = tarfile.FIFOTYPE
                else:
                    raise AssertionError(f"unknown bad tar kind: {kind}")
            if data is None:
                archive.addfile(info)
            else:
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
    write_canonical_gzip(path, encoded_tar.getvalue())


def self_test() -> None:
    for name in ["../escape", "/absolute", "C:/absolute", "root\\escape", "root/./escape"]:
        expect_rejected(lambda value=name: assert_safe_name(value), f"unsafe path {name}")
    expect_rejected(lambda: assert_exact_names(["a", "a"], ["a", "a"]), "duplicate")
    expect_rejected(lambda: assert_exact_names(["a", "A"], ["a", "A"]), "case-fold collision")

    with tempfile.TemporaryDirectory(prefix="moonhostabi-archive-self-test-") as temporary:
        root = Path(temporary)
        valid = root / "valid.tar.gz"
        create_bad_tar(valid, None)
        validate_tar(valid, "0.1.1")
        encoded = valid.read_bytes()
        gzip_mutations = {
            "nonzero mtime": encoded[:4] + b"\x01\x00\x00\x00" + encoded[8:],
            "header flags": encoded[:3] + b"\x08" + encoded[4:],
            "non-linux os": encoded[:9] + b"\xff" + encoded[10:],
            "concatenated member": encoded + encoded,
            "trailing data": encoded + b"unexpected",
        }
        for label, mutated in gzip_mutations.items():
            archive = root / f"gzip-{label.replace(' ', '-')}.tar.gz"
            archive.write_bytes(mutated)
            expect_rejected(lambda value=archive: validate_tar(value, "0.1.1"), label)
        decoded_valid = zlib.decompress(encoded, wbits=31)
        with tarfile.open(fileobj=io.BytesIO(decoded_valid), mode="r:") as valid_archive:
            valid_members = valid_archive.getmembers()
        payload_end = max(member.offset_data + member.size for member in valid_members)
        aligned_payload_end = ((payload_end + 511) // 512) * 512
        tar_mutations = {
            "tar trailing nonzero": decoded_valid + b"EVIL",
            "tar truncated end blocks": decoded_valid[:aligned_payload_end + 512],
        }
        for label, mutated_tar in tar_mutations.items():
            archive = root / f"{label.replace(' ', '-')}.tar.gz"
            write_canonical_gzip(archive, mutated_tar)
            expect_rejected(lambda value=archive: validate_tar(value, "0.1.1"), label)
        for kind in ["symlink", "hardlink", "device", "fifo"]:
            archive = root / f"{kind}.tar.gz"
            create_bad_tar(archive, kind)
            expect_rejected(lambda value=archive: validate_tar(value, "0.1.1"), f"tar {kind}")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate")
    validate.add_argument("--archive", required=True, type=Path)
    validate.add_argument("--platform", required=True, choices=["windows", "linux"])
    validate.add_argument("--version", required=True)
    validate.add_argument("--extract", type=Path)
    validate.add_argument("--allow-simulated-metadata", action="store_true")

    mock = subparsers.add_parser("create-mock")
    mock.add_argument("--archive", required=True, type=Path)
    mock.add_argument("--platform", required=True, choices=["windows", "linux"])
    mock.add_argument("--version", required=True)
    mock.add_argument("--source-root", required=True, type=Path)

    mutate = subparsers.add_parser("mutate-tar-trailing")
    mutate.add_argument("--archive", required=True, type=Path)
    mutate.add_argument("--output", required=True, type=Path)

    subparsers.add_parser("self-test")

    args = parser.parse_args()
    if args.command == "self-test":
        self_test()
        print("MOONHOSTABI_RELEASE_ARCHIVE_SELF_TEST=GO")
        return 0
    if args.command == "create-mock":
        create_mock(args.archive, args.source_root, args.version, args.platform)
        return 0
    if args.command == "mutate-tar-trailing":
        append_tar_trailing(args.archive, args.output)
        return 0

    records, payloads = validate_archive(
        args.archive,
        args.version,
        args.platform,
        args.allow_simulated_metadata,
    )
    root = platform_root(args.version, args.platform)
    if args.extract is not None:
        extract_payloads(args.extract, root, payloads, args.platform)
    print(
        json.dumps(
            {
                "schemaVersion": 1,
                "platform": args.platform,
                "architecture": "x86_64",
                "root": root,
                "files": records,
            },
            ensure_ascii=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, AssertionError, tarfile.TarError, zipfile.BadZipFile) as error:
        raise SystemExit(f"release archive validation failed: {error}")
