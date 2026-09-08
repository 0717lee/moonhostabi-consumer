from __future__ import annotations

import argparse
import copy
from pathlib import Path
import re
import sys
from typing import Any

import yaml


ACTION_PINS = {
    "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",  # v7.0.1
    "actions/setup-node": "820762786026740c76f36085b0efc47a31fe5020",  # v7.0.0
    "actions/setup-python": "5fda3b95a4ea91299a34e894583c3862153e4b97",  # v7.0.0
    "actions/upload-artifact": "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",  # v7.0.1
    "actions/download-artifact": "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",  # v8.0.1
}
ACTION_PATTERN = re.compile(r"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-f]{40})\Z")


# The installer/archive selector and the identities printed by the installed
# tools are different contracts. Keep both explicit so a build-tool version
# cannot accidentally be passed to the official installer.
MOONBIT_CONTRACT_ENV = {
    "MOONBIT_SNAPSHOT": "0.10.11+6ff76a5f9",
    "MOONBIT_SNAPSHOT_URL": "0.10.11%2B6ff76a5f9",
    "MOONBIT_LINUX_ARCHIVE_SHA256": (
        "9573f4df56ff7fe99aa200ddeabc379919e80203c37986642d8e74add1a7e7be"
    ),
    "MOONBIT_WINDOWS_ARCHIVE_SHA256": (
        "f08e1d54efff3a99319f686b11ceb1a1454288e460e7f20a77219f8d4e08f538"
    ),
    "MOONBIT_VERSION": "0.1.20260827",
    "MOONBIT_COMMIT": "d0aaa07",
    "MOONC_VERSION": "v0.10.11+6ff76a5f9",
    "MOONBIT_RELEASE_DATE": "2026-08-27",
    "MOONC_RELEASE_DATE": "2026-08-28",
    "MOONBIT_UNIX_INSTALLER_SHA256": (
        "46495f8cdc0050f79b6cb195d66478d101cb3601d68506568fbe377fcdf2a9fe"
    ),
    "MOONBIT_WINDOWS_INSTALLER_SHA256": (
        "a5101e91ffa9905fb25cd009b9a4aa942971a294bd055c89836e3af89b710c64"
    ),
}


class UniqueKeyLoader(yaml.BaseLoader):
    pass


def construct_unique_mapping(
    loader: UniqueKeyLoader,
    node: yaml.MappingNode,
    deep: bool = False,
) -> dict[str, Any]:
    mapping: dict[str, Any] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, str):
            raise ValueError(f"workflow mapping key must be text: {key!r}")
        if key in mapping:
            raise ValueError(f"duplicate workflow mapping key: {key}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_unique_mapping,
)


def load_workflow(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    if text.startswith("\ufeff") or "\r" in text or "\t" in text:
        raise ValueError(f"{path.name}: expected UTF-8 without BOM, LF, and spaces")
    document = yaml.load(text, Loader=UniqueKeyLoader)
    if not isinstance(document, dict):
        raise ValueError(f"{path.name}: expected top-level mapping")
    return document


def recursive_scalars(value: Any) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        result: list[str] = []
        for item in value:
            result.extend(recursive_scalars(item))
        return result
    if isinstance(value, dict):
        result = []
        for key, item in value.items():
            result.append(str(key))
            result.extend(recursive_scalars(item))
        return result
    return []


def workflow_steps(document: dict[str, Any]) -> list[dict[str, Any]]:
    jobs = document.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        raise ValueError("workflow must define jobs")
    steps: list[dict[str, Any]] = []
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            raise ValueError(f"job {job_name} must be a mapping")
        job_steps = job.get("steps")
        if not isinstance(job_steps, list) or not job_steps:
            raise ValueError(f"job {job_name} must define steps")
        for step in job_steps:
            if not isinstance(step, dict):
                raise ValueError(f"job {job_name} contains a non-mapping step")
            steps.append(step)
    return steps


def assert_permissions(document: dict[str, Any], label: str) -> None:
    if document.get("permissions") != {"contents": "read"}:
        raise ValueError(f"{label}: permissions must be exactly contents: read")
    jobs = document.get("jobs", {})
    if isinstance(jobs, dict) and any(
        isinstance(job, dict) and "permissions" in job for job in jobs.values()
    ):
        raise ValueError(f"{label}: job-level permission overrides are forbidden")


def assert_action_pins(document: dict[str, Any], label: str) -> None:
    for step in workflow_steps(document):
        uses = step.get("uses")
        if uses is None:
            continue
        if not isinstance(uses, str):
            raise ValueError(f"{label}: action uses must be text")
        match = ACTION_PATTERN.fullmatch(uses)
        if match is None:
            raise ValueError(f"{label}: action is not pinned to a full lowercase SHA: {uses}")
        repository, sha = match.groups()
        if ACTION_PINS.get(repository) != sha:
            raise ValueError(f"{label}: action pin is not an approved official release: {uses}")


def assert_no_release_authority(document: dict[str, Any], label: str) -> None:
    joined = "\n".join(recursive_scalars(document))
    forbidden = [
        r"\$\{\{\s*secrets\.",
        r"\$\{\{\s*github\.token\s*\}\}",
        r"\bGITHUB_TOKEN\b",
        r"\bGH_TOKEN\b",
        r"(?i)\bgh\s+release\b",
        r"(?i)\bgh\s+api\b",
        r"(?i)actions/github-script",
        r"(?i)actions/create-release",
        r"(?i)softprops/action-gh-release",
        r"(?i)repos/[^\s]+/releases(?:\s|$)",
    ]
    for pattern in forbidden:
        if re.search(pattern, joined):
            raise ValueError(f"{label}: forbidden secret or release-publication authority: {pattern}")
    for step in workflow_steps(document):
        run = step.get("run")
        if isinstance(run, str) and re.search(
            r"\$\{\{\s*(?:inputs|github\.event)\.", run
        ):
            raise ValueError(f"{label}: untrusted workflow data must enter run steps through env")


def matrix_pairs(job: dict[str, Any]) -> set[tuple[str, str]]:
    try:
        include = job["strategy"]["matrix"]["include"]
    except (KeyError, TypeError) as error:
        raise ValueError("matrix job must use strategy.matrix.include") from error
    if not isinstance(include, list):
        raise ValueError("matrix include must be a list")
    result: set[tuple[str, str]] = set()
    for item in include:
        if not isinstance(item, dict):
            raise ValueError("matrix include item must be a mapping")
        pair = (str(item.get("os", "")), str(item.get("platform", item.get("name", ""))))
        if pair in result:
            raise ValueError(f"duplicate matrix entry: {pair}")
        result.add(pair)
    return result


def step_uses(steps: list[dict[str, Any]], repository: str) -> bool:
    prefix = repository + "@"
    return any(isinstance(step.get("uses"), str) and step["uses"].startswith(prefix) for step in steps)


def action_steps(steps: list[dict[str, Any]], repository: str) -> list[dict[str, Any]]:
    prefix = repository + "@"
    return [
        step
        for step in steps
        if isinstance(step.get("uses"), str) and step["uses"].startswith(prefix)
    ]


def assert_exact_with(
    step: dict[str, Any],
    expected: dict[str, str],
    label: str,
) -> None:
    actual = step.get("with")
    if actual != expected:
        raise ValueError(f"{label}: action inputs do not match the fixed handoff contract")


def run_text(steps: list[dict[str, Any]]) -> str:
    return "\n".join(str(step.get("run", "")) for step in steps)


def assert_dependency_resolution_order(
    text: str,
    label: str,
    update_marker: str = "moon update",
    check_marker: str = "moon check",
    patch_marker: str = "apply-wasm-core-patch.ps1",
) -> None:
    update_index = text.find(update_marker)
    check_index = text.find(check_marker)
    patch_index = text.find(patch_marker)
    if (
        update_index < 0
        or check_index < 0
        or patch_index < 0
        or not update_index < check_index < patch_index
    ):
        raise ValueError(
            f"{label}: dependency resolution must run moon update, moon check, "
            "then the guarded wasm_core patch"
        )


def assert_moonbit_contract(job: dict[str, Any], text: str, label: str) -> None:
    """Require the pinned installer snapshot and all three reported identities."""
    env = job.get("env")
    if not isinstance(env, dict):
        raise ValueError(f"{label}: MoonBit contract must be declared at job level")
    for key, expected in MOONBIT_CONTRACT_ENV.items():
        if env.get(key) != expected:
            raise ValueError(
                f"{label}: {key} must be the fixed MoonBit contract value {expected!r}"
            )

    required_fragments = (
        'MOONBIT_INSTALL_VERSION="$MOONBIT_SNAPSHOT" bash "$installer"',
        "$env:MOONBIT_INSTALL_VERSION = $env:MOONBIT_SNAPSHOT",
        "https://cli.moonbitlang.com/install/unix.sh",
        'echo "$MOONBIT_UNIX_INSTALLER_SHA256  $installer" | sha256sum -c -',
        "binaries/$MOONBIT_SNAPSHOT_URL/moonbit-linux-x86_64.tar.gz",
        "binaries/$env:MOONBIT_SNAPSHOT_URL/moonbit-windows-x86_64.zip",
        'echo "$MOONBIT_LINUX_ARCHIVE_SHA256  $snapshot_archive" | sha256sum -c -',
        "https://cli.moonbitlang.com/install/powershell.ps1",
        "Get-FileHash -Algorithm SHA256 -LiteralPath $installer",
        "$env:MOONBIT_WINDOWS_INSTALLER_SHA256",
        "if ($actual -cne $env:MOONBIT_WINDOWS_INSTALLER_SHA256)",
        "Get-FileHash -Algorithm SHA256 -LiteralPath $snapshotArchive",
        "$env:MOONBIT_WINDOWS_ARCHIVE_SHA256",
        "if ($snapshotActual -cne $env:MOONBIT_WINDOWS_ARCHIVE_SHA256)",
        "moon version --all",
        "$identityLines = @(",
        "$moonVersion | Where-Object { $_ -cmatch '^(?:moon|moonc|moonrun) ' }",
        "$identityLines.Count -ne 3",
        "StartsWith($prefix, [StringComparison]::Ordinal)",
    )
    for fragment in required_fragments:
        if fragment not in text:
            raise ValueError(f"{label}: MoonBit contract fragment is missing: {fragment}")

    forbidden_fragments = (
        'MOONBIT_INSTALL_VERSION="$MOONBIT_VERSION"',
        "$env:MOONBIT_INSTALL_VERSION = $env:MOONBIT_VERSION",
    )
    for fragment in forbidden_fragments:
        if fragment in text:
            raise ValueError(f"{label}: installer must receive MOONBIT_SNAPSHOT, not MOONBIT_VERSION")
    if re.search(r"MOONBIT_INSTALL_VERSION\s*=\s*['\"]?latest\b", text, re.IGNORECASE):
        raise ValueError(f"{label}: mutable MoonBit installer versions are forbidden")

    prefix_match = re.search(
        r"\$expectedPrefixes\s*=\s*@\((.*?)\n\s*\)", text, re.DOTALL
    )
    if prefix_match is None:
        raise ValueError(f"{label}: three-line MoonBit identity prefix block is required")
    expected_prefixes = (
        '"moon $env:MOONBIT_VERSION ($env:MOONBIT_COMMIT $env:MOONBIT_RELEASE_DATE) "',
        '"moonc $env:MOONC_VERSION ($env:MOONC_RELEASE_DATE) "',
        '"moonrun $env:MOONBIT_VERSION ($env:MOONBIT_COMMIT $env:MOONBIT_RELEASE_DATE) "',
    )
    prefix_block = prefix_match.group(1)
    for prefix in expected_prefixes:
        if prefix not in prefix_block:
            raise ValueError(f"{label}: expected MoonBit identity prefix is missing: {prefix}")


def validate_ci(document: dict[str, Any]) -> None:
    label = "ci.yml"
    triggers = document.get("on")
    if not isinstance(triggers, dict) or set(triggers) != {"push", "pull_request", "workflow_dispatch"}:
        raise ValueError(f"{label}: triggers must be push, pull_request, workflow_dispatch")
    assert_permissions(document, label)
    assert_action_pins(document, label)
    assert_no_release_authority(document, label)
    jobs = document["jobs"]
    if set(jobs) != {"spike"}:
        raise ValueError(f"{label}: expected only spike job")
    job = jobs["spike"]
    pairs = matrix_pairs(job)
    if pairs != {
        ("ubuntu-latest", "Linux x86_64"),
        ("windows-latest", "Windows x86_64"),
    }:
        raise ValueError(f"{label}: matrix must exactly cover Linux/Windows x86_64")
    steps = job["steps"]
    text = run_text(steps)
    if "verify-spike.ps1" not in text or "git diff --exit-code" not in text:
        raise ValueError(f"{label}: full gate and dirty-tree checks are required")
    if not step_uses(steps, "actions/setup-python") or "requirements-workflow-validation.txt" not in text:
        raise ValueError(f"{label}: pinned Python/YAML validation setup is required")
    if not step_uses(steps, "actions/upload-artifact"):
        raise ValueError(f"{label}: failure diagnostics upload is required")
    assert_moonbit_contract(job, text, label)
    if "--index-url=https://pypi.org/simple --require-hashes" not in text:
        raise ValueError(f"{label}: workflow validator must install from hashed official PyPI")


def validate_release(document: dict[str, Any]) -> None:
    label = "release.yml"
    triggers = document.get("on")
    if not isinstance(triggers, dict) or set(triggers) != {"workflow_dispatch"}:
        raise ValueError(f"{label}: only workflow_dispatch is allowed")
    dispatch = triggers["workflow_dispatch"]
    try:
        version_input = dispatch["inputs"]["version"]
    except (KeyError, TypeError) as error:
        raise ValueError(f"{label}: workflow_dispatch version input is required") from error
    if not isinstance(version_input, dict) or version_input.get("required") != "true":
        raise ValueError(f"{label}: version input must be required")
    assert_permissions(document, label)
    assert_action_pins(document, label)
    assert_no_release_authority(document, label)
    jobs = document["jobs"]
    if set(jobs) != {"package", "aggregate"}:
        raise ValueError(f"{label}: jobs must be package and aggregate")

    package = jobs["package"]
    pairs = matrix_pairs(package)
    if pairs != {("ubuntu-latest", "linux"), ("windows-latest", "windows")}:
        raise ValueError(f"{label}: package matrix must be linux/windows x86_64")
    package_steps = package["steps"]
    package_text = run_text(package_steps)
    if "package-release.ps1" not in package_text:
        raise ValueError(f"{label}: package job must call package-release.ps1")
    if "${{ inputs.version }}" in package_text:
        raise ValueError(f"{label}: raw workflow input must enter through env, not run interpolation")
    if not step_uses(package_steps, "actions/upload-artifact"):
        raise ValueError(f"{label}: package job must upload immutable handoff artifacts")
    assert_moonbit_contract(package, package_text, label)
    assert_dependency_resolution_order(package_text, label)
    package_uploads = action_steps(package_steps, "actions/upload-artifact")
    if len(package_uploads) != 1:
        raise ValueError(f"{label}: package job must have exactly one upload handoff")
    assert_exact_with(
        package_uploads[0],
        {
            "name": "moonhostabi-package-${{ matrix.platform }}",
            "path": (
                "${{ runner.temp }}/moonhostabi-package/*\n"
                "${{ runner.temp }}/${{ matrix.platform }}.evidence.json\n"
            ),
            "if-no-files-found": "error",
            "compression-level": "0",
            "retention-days": "14",
        },
        f"{label} package upload",
    )

    aggregate = jobs["aggregate"]
    if aggregate.get("needs") != "package" or aggregate.get("runs-on") != "ubuntu-latest":
        raise ValueError(f"{label}: aggregate must need package and run on ubuntu-latest")
    aggregate_steps = aggregate["steps"]
    aggregate_text = run_text(aggregate_steps)
    if "create-release-aggregate.ps1" not in aggregate_text:
        raise ValueError(f"{label}: aggregate job must call create-release-aggregate.ps1")
    if "-AllowSimulatedEvidence" in aggregate_text:
        raise ValueError(f"{label}: remote aggregation must forbid simulated evidence")
    if not step_uses(aggregate_steps, "actions/download-artifact"):
        raise ValueError(f"{label}: aggregate job must download platform handoffs")
    if not step_uses(aggregate_steps, "actions/upload-artifact"):
        raise ValueError(f"{label}: aggregate job must upload one dry-run release artifact")
    downloads = action_steps(aggregate_steps, "actions/download-artifact")
    uploads = action_steps(aggregate_steps, "actions/upload-artifact")
    if len(downloads) != 1 or len(uploads) != 1:
        raise ValueError(f"{label}: aggregate must have one download and one upload")
    assert_exact_with(
        downloads[0],
        {
            "pattern": "moonhostabi-package-*",
            "path": "${{ runner.temp }}/moonhostabi-release-input",
            "merge-multiple": "true",
        },
        f"{label} aggregate download",
    )
    assert_exact_with(
        uploads[0],
        {
            "name": "moonhostabi-release-dry-run",
            "path": "${{ runner.temp }}/moonhostabi-release-output/*",
            "if-no-files-found": "error",
            "compression-level": "0",
            "retention-days": "14",
        },
        f"{label} aggregate upload",
    )


def expect_failure(callback: Any, label: str) -> None:
    try:
        callback()
    except (ValueError, yaml.YAMLError):
        return
    raise AssertionError(f"negative workflow self-test unexpectedly passed: {label}")


def self_test(ci: dict[str, Any], release: dict[str, Any], repository: Path) -> None:
    duplicate = "name: first\nname: second\non:\n  workflow_dispatch:\n"
    expect_failure(lambda: yaml.load(duplicate, Loader=UniqueKeyLoader), "duplicate key")

    release_push = copy.deepcopy(release)
    release_push["on"]["push"] = {}
    expect_failure(lambda: validate_release(release_push), "release push trigger")

    unpinned = copy.deepcopy(ci)
    unpinned["jobs"]["spike"]["steps"][0]["uses"] = "actions/checkout@v7"
    expect_failure(lambda: validate_ci(unpinned), "tag-pinned action")

    secret = copy.deepcopy(release)
    secret["jobs"]["aggregate"]["steps"].append({"run": "echo ${{ secrets.RELEASE_TOKEN }}"})
    expect_failure(lambda: validate_release(secret), "secret reference")

    github_token = copy.deepcopy(release)
    github_token["jobs"]["aggregate"]["steps"].append({"run": "echo ${{ github.token }}"})
    expect_failure(lambda: validate_release(github_token), "github token reference")

    raw_input = copy.deepcopy(release)
    raw_input["jobs"]["aggregate"]["steps"].append({"run": "echo ${{ inputs.version }}"})
    expect_failure(lambda: validate_release(raw_input), "raw input in run")

    duplicate_matrix = copy.deepcopy(release)
    duplicate_matrix["jobs"]["package"]["strategy"]["matrix"]["include"].append(
        copy.deepcopy(
            duplicate_matrix["jobs"]["package"]["strategy"]["matrix"]["include"][0]
        )
    )
    expect_failure(lambda: validate_release(duplicate_matrix), "duplicate matrix entry")

    mutable_toolchain = copy.deepcopy(release)
    mutable_toolchain["jobs"]["package"]["steps"][2]["run"] = (
        mutable_toolchain["jobs"]["package"]["steps"][2]["run"].replace(
            'MOONBIT_INSTALL_VERSION="$MOONBIT_SNAPSHOT"',
            'MOONBIT_INSTALL_VERSION="$MOONBIT_VERSION"',
        )
    )
    expect_failure(lambda: validate_release(mutable_toolchain), "mutable toolchain install")

    wrong_snapshot = copy.deepcopy(release)
    wrong_snapshot["jobs"]["package"]["env"]["MOONBIT_SNAPSHOT"] = (
        MOONBIT_CONTRACT_ENV["MOONBIT_VERSION"]
    )
    expect_failure(lambda: validate_release(wrong_snapshot), "snapshot/build identity mix-up")

    wrong_archive_hash = copy.deepcopy(release)
    wrong_archive_hash["jobs"]["package"]["env"]["MOONBIT_WINDOWS_ARCHIVE_SHA256"] = "0" * 64
    expect_failure(lambda: validate_release(wrong_archive_hash), "wrong MoonBit archive hash")

    missing_moonc_identity = copy.deepcopy(release)
    verify_step = next(
        step
        for step in missing_moonc_identity["jobs"]["package"]["steps"]
        if step.get("name") == "Verify exact MoonBit toolchain"
    )
    verify_step["run"] = verify_step["run"].replace(
        '"moonc $env:MOONC_VERSION ($env:MOONC_RELEASE_DATE) "',
        '"moonc $env:MOONC_VERSION (wrong-date) "',
    )
    expect_failure(lambda: validate_release(missing_moonc_identity), "missing moonc identity")

    missing_dependency_check = copy.deepcopy(release)
    resolve_step = next(
        step
        for step in missing_dependency_check["jobs"]["package"]["steps"]
        if step.get("name") == "Resolve dependencies and guarded parser patch"
    )
    resolve_step["run"] = resolve_step["run"].replace(
        "moon check\nif ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }\n",
        "",
    )
    expect_failure(lambda: validate_release(missing_dependency_check), "patch before dependency resolution")

    first_line_only = copy.deepcopy(release)
    verify_step = next(
        step
        for step in first_line_only["jobs"]["package"]["steps"]
        if step.get("name") == "Verify exact MoonBit toolchain"
    )
    verify_step["run"] = verify_step["run"].replace(
        "$moonVersion | Where-Object { $_ -cmatch '^(?:moon|moonc|moonrun) ' }",
        "$moonVersion[0]",
    )
    expect_failure(lambda: validate_release(first_line_only), "first-line-only identity check")

    wrong_handoff = copy.deepcopy(release)
    upload = action_steps(
        wrong_handoff["jobs"]["package"]["steps"], "actions/upload-artifact"
    )[0]
    upload["with"]["name"] = "unexpected"
    expect_failure(lambda: validate_release(wrong_handoff), "wrong artifact handoff")

    missing_download = copy.deepcopy(release)
    missing_download["jobs"]["aggregate"]["steps"] = [
        step
        for step in missing_download["jobs"]["aggregate"]["steps"]
        if not str(step.get("uses", "")).startswith("actions/download-artifact@")
    ]
    expect_failure(lambda: validate_release(missing_download), "missing artifact download")

    verify_spike = (repository / "scripts" / "verify-spike.ps1").read_text(encoding="utf-8")
    assert_dependency_resolution_order(
        verify_spike,
        "verify-spike.ps1",
        update_marker="Arguments @('update')",
        check_marker="Arguments @('check') -Description 'moon check (dependency resolution)'",
    )
    missing_verify_check = verify_spike.replace(
        "  Invoke-Checked -FilePath $moonExecutable -Arguments @('check') -Description 'moon check (dependency resolution)'\n",
        "",
    )
    expect_failure(
        lambda: assert_dependency_resolution_order(
            missing_verify_check,
            "verify-spike.ps1",
            update_marker="Arguments @('update')",
            check_marker="Arguments @('check') -Description 'moon check (dependency resolution)'",
        ),
        "verify-spike patch before dependency resolution",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if yaml.__version__ != "6.0.3":
        raise ValueError(f"expected PyYAML 6.0.3, received {yaml.__version__}")
    workflow_root = args.repository.resolve() / ".github" / "workflows"
    repository = args.repository.resolve()
    verify_spike = (repository / "scripts" / "verify-spike.ps1").read_text(encoding="utf-8")
    assert_dependency_resolution_order(
        verify_spike,
        "verify-spike.ps1",
        update_marker="Arguments @('update')",
        check_marker="Arguments @('check') -Description 'moon check (dependency resolution)'",
    )
    ci = load_workflow(workflow_root / "ci.yml")
    release = load_workflow(workflow_root / "release.yml")
    validate_ci(ci)
    validate_release(release)
    if args.self_test:
        self_test(ci, release, repository)
    print("MOONHOSTABI_WORKFLOW_VALIDATION=GO")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, AssertionError, yaml.YAMLError) as error:
        print(f"workflow validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
