from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
import tempfile
from typing import Iterable


LINK_PATTERN = re.compile(r"(?<!!)\[[^\]]+\]\(([^)\s]+)(?:\s+['\"][^)]*)?\)")
COMMAND_PATH_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_.\-/])((?:scripts|fixtures|docs|cmd)/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)"
)
HEADING_PATTERN = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$", re.MULTILINE)
CODE_FENCE_PATTERN = re.compile(r"```[^\r\n`]*\n(.*?)```", re.DOTALL)
FORBIDDEN_PATTERN = re.compile(
    r"(?i)(?:\bprivate\b|\binternal\b|\bcredentials?\b|\bsecrets?\b|\.codex|"
    r"GITHUB_TOKEN|GH_TOKEN|\$HOME|\$env:|\$\{\{|[A-Za-z]:[\\/]|/Users/|/home/)"
)
STALE_PATTERN = re.compile(
    r"(?i)(?:\b(?:no|without|never)\s+(?:a\s+)?verify\b|"
    r"\b(?:no|without|never)\s+(?:a\s+)?bundle\b|"
    r"\bdoes\s+not\s+verify\b|未(?:校验|验证)[^。\n]{0,20}(?:export|导出))"
)
VALIDATION_LEAK_PATTERN = re.compile(
    r"(?i)(?:"
    r"[A-Za-z]:[\\/](?:Users|home|Windows|Temp|tmp|var)[\\/]"
    r"|/(?:Users|home|tmp|var)/"
    r"|\$(?:HOME|env:)"
    r"|-----BEGIN(?: [A-Z]+)? PRIVATE KEY-----"
    r"|\bprivate[-_ ]key\b\s*[:=]"
    r"|\bBearer\s+[A-Za-z0-9._~+/=-]{16,}"
    r"|\b(?:token|api[_-]?key|password|secret)\s*[:=]\s*[\"']?[A-Za-z0-9._~+/=-]{8,}"
    r")"
)


def line_number(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def read_text(path: Path) -> str:
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError(f"{path}: UTF-8 BOM is not allowed")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError(f"{path}: invalid UTF-8: {error}") from error
    if "\r" in text or "\t" in text:
        raise ValueError(f"{path}: expected LF line endings and no tabs")
    if not text.endswith("\n"):
        raise ValueError(f"{path}: expected a final LF")
    return text


def heading_anchor(title: str) -> str:
    title = re.sub(r"[`*_~]", "", title).lower()
    title = re.sub(r"[^\w\s-]", "", title, flags=re.UNICODE)
    return re.sub(r"\s+", "-", title.strip())


def anchors(text: str) -> set[str]:
    return {heading_anchor(match.group(2)) for match in HEADING_PATTERN.finditer(text)}


def iter_links(text: str) -> Iterable[tuple[int, str]]:
    for match in LINK_PATTERN.finditer(text):
        yield line_number(text, match.start()), match.group(1).strip("<>")


def validate_links(path: Path, text: str, repository: Path) -> None:
    for number, target in iter_links(text):
        if target.startswith(("https://", "http://", "mailto:")):
            continue
        target_path, _, fragment = target.partition("#")
        if not target_path:
            if fragment and fragment not in anchors(text):
                raise ValueError(f"{path}:{number}: missing heading anchor '#{fragment}'")
            continue
        candidate = (path.parent / target_path).resolve(strict=False)
        try:
            candidate.relative_to(repository)
        except ValueError as error:
            raise ValueError(f"{path}:{number}: link escapes repository: {target}") from error
        if not candidate.exists():
            raise ValueError(f"{path}:{number}: link target does not exist: {target}")
        if fragment:
            linked_text = read_text(candidate) if candidate.suffix.lower() == ".md" else ""
            if linked_text and fragment not in anchors(linked_text):
                raise ValueError(f"{path}:{number}: missing target anchor: {target}")


def code_blocks(text: str) -> Iterable[tuple[int, str]]:
    for match in CODE_FENCE_PATTERN.finditer(text):
        yield line_number(text, match.start()), match.group(1)


def validate_command_paths(path: Path, text: str, repository: Path) -> None:
    for start, block in code_blocks(text):
        if re.search(r"(?i)(?:[A-Za-z]:[\\/]|/Users/|/home/|\$HOME|\$env:|\$\{\{)", block):
            raise ValueError(f"{path}:{start}: command contains an absolute or hidden path")
        if re.search(r"(?:\.\./|\.\.\\|/\.\.(?:/|$)|\\\.\.(?:\\|$))", block):
            raise ValueError(f"{path}:{start}: command contains an upward traversal")
        for match in COMMAND_PATH_PATTERN.finditer(block):
            target = (repository / match.group(1)).resolve(strict=False)
            try:
                target.relative_to(repository)
            except ValueError as error:
                raise ValueError(
                    f"{path}:{start}: command path escapes repository: {match.group(1)}"
                ) from error
            if not target.exists():
                raise ValueError(f"{path}:{start}: command path does not exist: {match.group(1)}")


def validate_validation_leaks(path: Path, text: str) -> None:
    leak = VALIDATION_LEAK_PATTERN.search(text)
    if leak:
        raise ValueError(
            f"{path}:{line_number(text, leak.start())}: validation document contains a concrete secret/path marker"
        )


def validate_bundle_doc(path: Path, text: str, repository: Path) -> None:
    validate_links(path, text, repository)
    validate_command_paths(path, text, repository)
    if "$absoluteNewArchivePath" in text:
        raise ValueError(f"{path}: bundle example contains an undefined output variable")


def validate_headings(path: Path, text: str) -> None:
    headings = list(HEADING_PATTERN.finditer(text))
    if sum(len(match.group(1)) == 1 for match in headings) != 1:
        raise ValueError(f"{path}: expected exactly one H1 heading")
    levels = [len(match.group(1)) for match in headings]
    for previous, current in zip(levels, levels[1:], strict=False):
        if current > previous + 1:
            raise ValueError(f"{path}: heading level skips from H{previous} to H{current}")


def validate_content(path: Path, text: str) -> None:
    forbidden = FORBIDDEN_PATTERN.search(text)
    if forbidden:
        raise ValueError(
            f"{path}:{line_number(text, forbidden.start())}: forbidden private/internal/credential marker"
        )
    stale = STALE_PATTERN.search(text)
    if stale:
        raise ValueError(f"{path}:{line_number(text, stale.start())}: stale claim")


def validate_quickstart(repository: Path) -> None:
    readme_path = repository / "README.md"
    quickstart_path = repository / "docs" / "quickstart.md"
    validation_path = repository / "docs" / "validation.md"
    bundle_path = repository / "fixtures" / "reproduction" / "README.md"
    readme = read_text(readme_path)
    quickstart = read_text(quickstart_path)
    validation = read_text(validation_path)
    bundle = read_text(bundle_path)

    for path, text in (
        (readme_path, readme),
        (quickstart_path, quickstart),
        (validation_path, validation),
        (bundle_path, bundle),
    ):
        validate_links(path, text, repository)
    validate_command_paths(readme_path, readme, repository)
    validate_command_paths(quickstart_path, quickstart, repository)
    validate_bundle_doc(bundle_path, bundle, repository)
    validate_headings(quickstart_path, quickstart)
    validate_content(readme_path, readme)
    validate_content(quickstart_path, quickstart)
    validate_validation_leaks(validation_path, validation)
    stale_validation = STALE_PATTERN.search(validation)
    if stale_validation:
        raise ValueError(
            f"{validation_path}:{line_number(validation, stale_validation.start())}: stale claim"
        )

    required_quickstart = (
        "MoonHostABI",
        "MOONHOSTABI_VERIFY_STATUS=GO",
        "MOONHOSTABI_BUNDLE_STATUS=GO",
        "MOONHOSTABI_PACKAGE_STATUS=GO",
        "report-schema.md",
        "fixtures/reproduction/README.md",
        "artifact",
        "baseline",
        "provenance",
        "compatibility",
        "contract",
        "generator",
        "Windows",
        "Linux",
        "mock",
        "remote",
        "pending",
        "pwsh -NoProfile -File scripts/verify-command.ps1",
        "pwsh -NoProfile -File scripts/verify-reproduction-bundle.ps1",
        "pwsh -NoProfile -File scripts/verify-release-packaging.ps1",
    )
    for phrase in required_quickstart:
        if phrase not in quickstart:
            raise ValueError(f"{quickstart_path}: required quickstart phrase is missing: {phrase}")
    if readme.find("docs/quickstart.md") == -1:
        raise ValueError(f"{readme_path}: judge quickstart link is missing")
    first_section = readme[: readme.find("## CLI surface") if "## CLI surface" in readme else len(readme)]
    for phrase in (
        "pwsh -NoProfile -File scripts/verify-command.ps1",
        "pwsh -NoProfile -File scripts/verify-reproduction-bundle.ps1",
        "pwsh -NoProfile -File scripts/verify-release-packaging.ps1",
        "MOONHOSTABI_VERIFY_STATUS=GO",
        "MOONHOSTABI_BUNDLE_STATUS=GO",
        "MOONHOSTABI_PACKAGE_STATUS=GO",
    ):
        if phrase not in first_section:
            raise ValueError(f"{readme_path}: first-screen quickstart phrase is missing: {phrase}")
    required_validation = (
        "Task 8",
        "MOONHOSTABI_VERIFY_STATUS=GO",
        "MOONHOSTABI_BUNDLE_STATUS=GO",
        "MOONHOSTABI_PACKAGE_STATUS=GO",
        "remote",
        "pending",
    )
    for phrase in required_validation:
        if phrase not in validation:
            raise ValueError(f"{validation_path}: Task 8 evidence phrase is missing: {phrase}")


def expect_failure(callback, label: str) -> None:
    try:
        callback()
    except (OSError, ValueError):
        return
    raise AssertionError(f"quickstart validator negative unexpectedly passed: {label}")


def self_test(repository: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="moonhostabi-quickstart-validator-") as temporary:
        root = Path(temporary)
        target = root / "docs"
        target.mkdir()
        existing = target / "ok.md"
        existing.write_text("# Existing\n", encoding="utf-8", newline="")
        expect_failure(
            lambda: validate_links(target / "x.md", "[missing](missing.md)\n", root),
            "missing link",
        )
        expect_failure(
            lambda: validate_links(target / "x.md", "[escape](../../outside.md)\n", root),
            "escaping link",
        )
        expect_failure(
            lambda: validate_command_paths(
                target / "x.md", "```powershell\npwsh scripts/missing.ps1\n```\n", root
            ),
            "missing command path",
        )
        expect_failure(
            lambda: validate_command_paths(
                target / "x.md", "```shell\npwsh scripts/missing.ps1\n```\n", root
            ),
            "shell fence command path",
        )
        expect_failure(
            lambda: validate_command_paths(
                target / "x.md", "```cmd\npwsh ../scripts/verify-command.ps1\n```\n", root
            ),
            "upward command path",
        )
        expect_failure(
            lambda: validate_command_paths(
                target / "README.md", "```console\npwsh C:\\Users\\judge\\run.ps1\n```\n", root
            ),
            "README absolute command path",
        )
        expect_failure(
            lambda: validate_validation_leaks(
                target / "validation.md", "Authorization: Bearer abcdefghijklmnop\n"
            ),
            "validation bearer leak",
        )
        expect_failure(
            lambda: validate_validation_leaks(
                target / "validation.md", "token=abcdefghijklmnop\n"
            ),
            "validation token leak",
        )
        expect_failure(
            lambda: validate_bundle_doc(
                target / "bundle.md",
                "$absoluteNewArchivePath\n",
                root,
            ),
            "undefined bundle output variable",
        )
        expect_failure(lambda: validate_content(target / "x.md", "internal credential\n"), "sensitive words")
        expect_failure(lambda: validate_content(target / "x.md", "There is no verify step.\n"), "stale claim")
        expect_failure(lambda: read_text(root / "missing.md"), "missing document")
        if not existing.exists():
            raise AssertionError("quickstart validator self-test fixture was not created")
    validate_quickstart(repository)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    repository = args.repository.resolve()
    if not repository.is_dir():
        raise ValueError(f"repository is not a directory: {repository}")
    if args.self_test:
        self_test(repository)
    else:
        validate_quickstart(repository)
    print("MOONHOSTABI_QUICKSTART_VALIDATION=GO")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, AssertionError) as error:
        print(f"quickstart validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
