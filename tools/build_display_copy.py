"""Build an opt-in, version-pinned Codex copy with narrow local defaults.

The Store installation, configuration, auth, and global feature gates are not
modified. This deliberately creates a locally modified (not vendor-signed)
executable. No integrity checks are disabled.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
from datetime import datetime, timezone
from pathlib import Path


BUILD = "26.1016.8120.0"
TARGET = "webview/assets/app-initial-83973da15da9.js"
EXPECTED_JS_SHA256 = "1fb9718e75ae6b4adc0dfd030028d570846d098892e774564db5efe491ce4691"
ORIGINAL = b"x=a&&d(Fh,`1186680773`);return{queryKey:"
REPLACEMENT = b"x=a" + b" " * (len(ORIGINAL) - len(b"x=a;return{queryKey:")) + b";return{queryKey:"
UPDATE_ORIGINAL = b"disableInAppUpdates:n?null:t,disableSparkleAutodownload:R"
UPDATE_REPLACEMENT = b"disableInAppUpdates:!0     ,disableSparkleAutodownload:!0"
UPDATE_PATCH_NAME = "disable Codex in-app update checks and automatic downloads"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def read_archive(path: Path):
    with path.open("rb") as stream:
        prefix = stream.read(16)
        fields = struct.unpack("<4I", prefix)
        raw = stream.read(fields[3])
    tree = json.loads(raw)
    return fields, raw, tree, 8 + fields[1]


def get_entry(tree: dict, name: str) -> dict:
    entry = tree
    for part in name.split("/"):
        entry = entry["files"][part]
    return entry


def read_entry(path: Path, offset: int, entry: dict) -> bytes:
    with path.open("rb") as stream:
        stream.seek(offset + int(entry["offset"]))
        data = stream.read(entry["size"])
    if len(data) != entry["size"]:
        raise ValueError("Truncated archive entry")
    return data


def patched_js(original: bytes) -> bytes:
    if sha(original) != EXPECTED_JS_SHA256:
        raise ValueError("Unrecognized app build: review the picker before patching")
    if original.count(ORIGINAL) != 1 or len(ORIGINAL) != len(REPLACEMENT):
        raise ValueError("Picker anchor or replacement length is not exact")
    result = original.replace(ORIGINAL, REPLACEMENT, 1)
    if (
        result.count(UPDATE_ORIGINAL) != 1
        or len(UPDATE_ORIGINAL) != len(UPDATE_REPLACEMENT)
    ):
        raise ValueError("Unrecognized updater-gate code")
    result = result.replace(UPDATE_ORIGINAL, UPDATE_REPLACEMENT, 1)
    # Two independent consumers must remain: runtime gate publication and tools.
    if result.count(b"1186680773") != 2:
        raise ValueError("Unexpected broader gate changes")
    for marker in (
        b"multiAgentMode:`1186680773`",
        b"includeUltraReasoningEffort:Mh(r,`1186680773`)",
    ):
        if result.count(marker) != original.count(marker):
            raise ValueError("Global multi-agent behavior must not be patched")
    if result.count(UPDATE_REPLACEMENT) != 1 or UPDATE_ORIGINAL in result:
        raise ValueError("Updater defaults were not patched exactly once")
    return result


def replace_unique(data: bytes, old: bytes, new: bytes) -> bytes:
    if len(old) != len(new) or data.count(old) != 1:
        raise ValueError("Integrity field is not unique or fixed-length")
    return data.replace(old, new, 1)


def updated_header(raw: bytes, entry: dict, before: bytes, after: bytes) -> bytes:
    integrity = entry["integrity"]
    if integrity["algorithm"] != "SHA256" or sha(before) != integrity["hash"]:
        raise ValueError("Source archive integrity mismatch")
    block_size = integrity["blockSize"]
    original_blocks = [sha(before[i:i + block_size]) for i in range(0, len(before), block_size)]
    if original_blocks != integrity["blocks"]:
        raise ValueError("Source block integrity mismatch")
    result = replace_unique(raw, sha(before).encode(), sha(after).encode())
    for old, new in zip(
        original_blocks,
        [sha(after[i:i + block_size]) for i in range(0, len(after), block_size)],
    ):
        if old != new:
            result = replace_unique(result, old.encode(), new.encode())
    return result


def verify_js(node: str, source: bytes):
    checked = subprocess.run(
        [node, "--input-type=module", "--check"],
        input=source, capture_output=True, timeout=60,
    )
    if checked.returncode:
        raise ValueError("Patched JavaScript syntax check failed")
    text = source.decode("utf-8")
    start = text.index("function eIo(")
    end = text.index("function nIo(", start)
    filters = text[start:end]
    if (
        text.count(UPDATE_REPLACEMENT.decode()) != 1
        or UPDATE_ORIGINAL.decode() in text
    ):
        raise ValueError("Update checks/downloads are not disabled in the copy")
    cases = r"""
const assert = require("node:assert/strict");
let checks = 0;
function check(condition, description) {
  assert.ok(condition, description);
  checks++;
}
function cFt(e) { return ["low","medium","high","xhigh","max","ultra"].includes(e); }
function queryFlag(a, gate) { const Fh={}; const d=()=>gate; __EXPRESSION__ return x; }
check(queryFlag(true,false) === true, "picker includes Ultra with rollout gate false");
check(queryFlag(false,false) === false, "explicit caller opt-out still respected");
check(queryFlag(false,true) === false, "explicit opt-out wins even with gate true");
function model(levels, extra={}) {
  return {model:"test-model",hidden:false,isDefault:true,
    supportedReasoningEfforts:levels.map(reasoningEffort=>({reasoningEffort})),...extra};
}
function pick(m, opts={}) {
  return eIo({
    apiKeyDaybreakSupported:false,authMethod:"apikey",availableModels:new Set(),
    defaultModel:"test-model",enabledReasoningEfforts:new Set(["high","max","ultra"]),
    hasConfiguredModelCatalog:true,includeUltraReasoningEffort:queryFlag(true,false),
    isCustomModelProvider:true,models:[m],useHiddenModels:false,...opts
  });
}
const levels = result => result.models.flatMap(m=>m.supportedReasoningEfforts.map(e=>e.reasoningEffort));
check(levels(pick(model(["high","max","ultra"]))).includes("ultra"), "catalog Ultra is retained");
check(!levels(pick(model(["high","max"]))).includes("ultra"), "no synthetic model capability");
check(!levels(pick(model(["high","ultra"]),{enabledReasoningEfforts:new Set(["high"])})).includes("ultra"),
      "desktop effort opt-out remains respected");
check(pick(model(["ultra"],{hidden:true})).models.length===0, "hidden models are not exposed");
check(pick(model(["ultra"],{availableAccessPrograms:{cyber:["restricted"]}})).models.length===0,
      "model access restrictions remain respected");
check(!levels(pick(model(["high","ultra"]),{includeUltraReasoningEffort:false})).includes("ultra"),
      "non-picker callers retain gate semantics");
check(!levels(pick(model(["medium","ultra"]),{authMethod:"copilot",
      enabledReasoningEfforts:new Set(["medium","ultra"])})).includes("ultra"),
      "Copilot reasoning policy remains unchanged");
const updater = new Function(
  "return ({disableInAppUpdates:!0,disableSparkleAutodownload:!0})"
)();
check(updater.disableInAppUpdates === true, "in-app update checks disabled");
check(updater.disableSparkleAutodownload === true, "automatic downloads disabled");
console.log(JSON.stringify({checks, status:"OK"}));
"""
    expression = REPLACEMENT.split(b";return{queryKey:", 1)[0].decode()
    cases = cases.replace("__EXPRESSION__", "let " + expression + ";")
    result = subprocess.run(
        [node, "-"], input=(filters + "\n" + cases).encode(),
        capture_output=True, timeout=30,
    )
    if result.returncode:
        raise ValueError("Behavior checks failed: " + result.stderr.decode(errors="replace")[:1500])
    return json.loads(result.stdout)


def verify_copy(output: Path):
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("changes") != [
        "picker query includeUltra flag only",
        UPDATE_PATCH_NAME,
    ]:
        raise ValueError("The approved local patch set changed")
    app = output / "app"
    archive = app / "resources/app.asar"
    exe = app / "ChatGPT.exe"
    _, raw, tree, offset = read_archive(archive)
    entry = get_entry(tree, TARGET)
    contents = read_entry(archive, offset, entry)
    if sha(contents) != manifest["patched_js_sha256"]:
        raise ValueError("Patched JavaScript no longer matches manifest")
    integrity = entry["integrity"]
    if sha(contents) != integrity["hash"]:
        raise ValueError("Patched file hash is invalid")
    blocks = [sha(contents[i:i + integrity["blockSize"]])
              for i in range(0, len(contents), integrity["blockSize"])]
    if blocks != integrity["blocks"]:
        raise ValueError("Patched block hashes are invalid")
    if sha(raw) != manifest["patched_header_sha256"]:
        raise ValueError("Archive header no longer matches manifest")
    if exe.read_bytes().count(sha(raw).encode()) != 1:
        raise ValueError("Executable is not bound to this archive header")
    if file_sha(exe) != manifest["patched_exe_sha256"]:
        raise ValueError("Experimental executable no longer matches manifest")
    if file_sha(archive) != manifest["patched_asar_sha256"]:
        raise ValueError("Experimental archive no longer matches manifest")
    return {"status": "OK", "build": BUILD, "display_only": True,
            "codex_in_app_updates_disabled": True}


def build(source: Path, output: Path, node: str):
    source, output = source.resolve(strict=True), output.resolve()
    if source.name != "app" or BUILD not in source.parent.name:
        raise ValueError("This experiment is restricted to the inspected app build")
    if output == source or source in output.parents or output in source.parents:
        raise ValueError("Source and output must be separate")
    if output.exists():
        raise ValueError("Output already exists; do not overwrite an experiment")
    archive = source / "resources/app.asar"
    exe = source / "ChatGPT.exe"
    _, raw, tree, offset = read_archive(archive)
    entry = get_entry(tree, TARGET)
    original = read_entry(archive, offset, entry)
    patched = patched_js(original)
    header = updated_header(raw, entry, original, patched)
    exe_before = exe.read_bytes()
    exe_after = replace_unique(exe_before, sha(raw).encode(), sha(header).encode())
    tests = verify_js(node, patched)
    source_asar_sha = file_sha(archive)
    print(json.dumps({"stage": "copying_official_app", "behavior_tests": tests}), flush=True)
    output.mkdir(parents=True)
    shutil.copytree(source, output / "app")
    dest_archive = output / "app/resources/app.asar"
    dest_exe = output / "app/ChatGPT.exe"
    if file_sha(dest_archive) != source_asar_sha or dest_exe.read_bytes() != exe_before:
        raise ValueError("Source changed during copy; experiment is not launchable")
    with dest_archive.open("r+b") as stream:
        stream.seek(16)
        stream.write(header)
        stream.seek(offset + int(entry["offset"]))
        stream.write(patched)
        stream.flush()
    dest_exe.write_bytes(exe_after)
    manifest = {
        "build": BUILD, "created_utc": datetime.now(timezone.utc).isoformat(),
        "source_app": str(source), "source_asar_sha256": source_asar_sha,
        "source_exe_sha256": sha(exe_before), "source_header_sha256": sha(raw),
        "source_js_sha256": sha(original), "patched_js_sha256": sha(patched),
        "patched_header_sha256": sha(header), "patched_exe_sha256": sha(exe_after),
        "patched_asar_sha256": file_sha(dest_archive),
        "target": TARGET, "changes": [
            "picker query includeUltra flag only",
            UPDATE_PATCH_NAME,
        ],
        "global_gate_changed": False, "behavior_tests": tests,
        "signature_notice": "Modified local copy; vendor signature no longer validates.",
        "ui_verification": "Pending restart using experimental launcher",
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    # Confirm that neither original file was changed by this build.
    if file_sha(archive) != source_asar_sha or exe.read_bytes() != exe_before:
        raise ValueError("Source files changed concurrently; review before use")
    print(json.dumps(verify_copy(output)), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-app", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--node", default="node")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    if args.verify_only:
        print(json.dumps(verify_copy(args.output)))
    elif args.source_app:
        build(args.source_app, args.output, args.node)
    else:
        parser.error("--source-app is required when building")


if __name__ == "__main__":
    main()
