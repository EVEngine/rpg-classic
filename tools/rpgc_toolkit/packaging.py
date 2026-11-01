"""Local SDK directory packaging, without downloads or executing any binaries.

This is an SDK-assisted distribution directory, not a guarantee that the target
OS supplies all native libraries. Symlinks in either input tree are rejected.
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

from .build import EXCLUDED_DIRS, EXCLUDED_NAMES, _safe_member
from .project import read_json

MANIFEST = 'RPGC-PACKAGE.json'
PLATFORMS = {'linux': 'eve', 'macos': 'eve', 'windows': 'eve.exe'}


def _sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def _files(root, source_filter=False):
    result = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        if source_filter:
            dirs[:] = [name for name in dirs if name not in EXCLUDED_DIRS]
        dirs.sort()
        for name in dirs:
            path = Path(directory) / name
            if path.is_symlink():
                raise ValueError(f'symlink directories are unsupported: {path}')
        for name in sorted(files):
            if source_filter and (name in EXCLUDED_NAMES or name.endswith(('.pyc', '.tmp', '.log', '.baked.json'))
                                  or (name.startswith('.rpgc-toolkit-') and name.endswith('.nut'))):
                continue
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink() or not path.is_file() or not _safe_member(relative):
                raise ValueError(f'unsafe/non-regular package input: {path}')
            result.append((relative, path))
    return sorted(result)


def _root(path, label):
    path = Path(path).absolute()
    if path.resolve() != path or not path.is_dir():
        raise ValueError(f'{label} must be a directory without symlinks or traversal')
    return path


def _launcher(platform):
    if platform == 'windows':
        return 'launch.cmd', ('@echo off\r\nsetlocal DisableDelayedExpansion\r\n'
                              'pushd "%~dp0game" || exit /b 1\r\n'
                              '"%~dp0engine\\bin\\eve.exe" run . %*\r\n'
                              'set "RPGC_EXIT=%ERRORLEVEL%"\r\npopd\r\nexit /b %RPGC_EXIT%\r\n')
    return 'launch.sh', ('#!/bin/sh\nset -eu\n'
                         'RPGC_PACKAGE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
                         'cd "$RPGC_PACKAGE_ROOT/game"\n'
                         'exec "$RPGC_PACKAGE_ROOT/engine/bin/eve" run . "$@"\n')


def _publish_directory(source, destination):
    """Atomic rename with no-replace semantics, including concurrent creators."""
    if os.name == 'nt':
        os.rename(source, destination)  # Windows rename refuses existing targets.
        return
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith('linux') and hasattr(libc, 'renameat2'):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        status = rename(-100, os.fsencode(source), -100, os.fsencode(destination), 1)  # RENAME_NOREPLACE
    elif sys.platform == 'darwin' and hasattr(libc, 'renamex_np'):
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        status = rename(os.fsencode(source), os.fsencode(destination), 4)  # RENAME_EXCL
    else:
        raise ValueError('this host does not support exclusive atomic directory publication')
    if status:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def package_project(root: Path, sdk: Path, output: Path, platform: str) -> dict:
    """Copy source and a user-supplied SDK into a new relocatable directory.

    Output must be outside the source project or under its top-level dist/build,
    and outside the SDK. Existing paths are never intentionally replaced. The
    staging directory is cleaned on failure and renamed only after verification.
    Symlinks are refused, including SDK library aliases: provide real files.
    """
    if platform not in PLATFORMS:
        raise ValueError('platform must be linux, macos, or windows')
    root, sdk = _root(root, 'project'), _root(sdk, 'SDK')
    output = Path(output).absolute()
    if output.resolve() != output or output.exists() or output.is_symlink():
        raise ValueError('output must be a new path without symlinks or traversal')
    if not output.parent.is_dir():
        raise ValueError('output parent directory must exist')
    if output.is_relative_to(root) and output.relative_to(root).parts[0] not in {'dist', 'build'}:
        raise ValueError('output must be outside the project or under top-level dist/build')
    if output.is_relative_to(sdk) or sdk.is_relative_to(root) or root.is_relative_to(sdk):
        raise ValueError('SDK, project, and output must not overlap (except project dist/build output)')
    if not (root / 'workflow.json').is_file():
        raise ValueError('project requires workflow.json')
    binary = sdk / 'bin' / PLATFORMS[platform]
    if not binary.is_file() or binary.is_symlink():
        raise ValueError(f'SDK requires a regular bin/{PLATFORMS[platform]} for {platform}')
    project_files, sdk_files = _files(root, True), _files(sdk)
    staging = Path(tempfile.mkdtemp(dir=output.parent, prefix='.rpgc-package-'))
    try:
        for prefix, entries in [('game', project_files), ('engine', sdk_files)]:
            for relative, source in entries:
                target = staging / prefix / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)
        if platform != 'windows':
            executable = staging / 'engine/bin/eve'
            executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        launcher_name, launcher_text = _launcher(platform)
        launcher = staging / launcher_name
        launcher.write_bytes(launcher_text.encode('utf-8'))
        launcher.chmod(0o755 if platform != 'windows' else 0o644)
        records = [dict(path=relative, bytes=path.stat().st_size, sha256=_sha256(path))
                   for relative, path in _files(staging)]
        manifest = dict(format='rpgc-sdk-package', version=1, platform=platform,
                        validated=False, osDependenciesBundled=False,
                        launcher=launcher_name, files=records)
        (staging / MANIFEST).write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + '\n', encoding='utf-8')
        verified = verify_package(staging)
        if not verified['ok']:
            raise ValueError(f"staged package verification failed: {verified['diagnostics']}")
        if output.exists() or output.is_symlink():
            raise ValueError('output was created during packaging')
        _publish_directory(staging, output)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return dict(ok=True, kind='sdk-package', path=str(output), platform=platform,
                validated=False, osDependenciesBundled=False, files=len(records),
                launcher=str(output / launcher_name))


def verify_package(path: Path) -> dict:
    """Check exact membership, safe paths and every payload's size/SHA-256.

    Integrity is not authenticity or engine content validation. This function
    never executes launchers or binaries and never follows symbolic links.
    """
    diagnostics, count = [], 0
    try:
        root = _root(path, 'package')
        actual = dict(_files(root))
        if MANIFEST not in actual:
            raise ValueError('missing package manifest')
        manifest = read_json(actual[MANIFEST])
        if (not isinstance(manifest, dict) or manifest.get('format') != 'rpgc-sdk-package'
                or type(manifest.get('version')) is not int or manifest['version'] != 1
                or manifest.get('platform') not in PLATFORMS or manifest.get('validated') is not False):
            raise ValueError('invalid package manifest')
        records = manifest.get('files')
        if not isinstance(records, list):
            raise ValueError('manifest files must be an array')
        declared = set()
        for record in records:
            if (not isinstance(record, dict) or not _safe_member(record.get('path'))
                    or type(record.get('bytes')) is not int or record['bytes'] < 0
                    or not isinstance(record.get('sha256'), str) or len(record['sha256']) != 64
                    or any(c not in '0123456789abcdef' for c in record['sha256'])):
                raise ValueError('invalid package file record')
            name = record['path']
            if name in declared or name == MANIFEST:
                raise ValueError('duplicate/reserved package file record')
            declared.add(name)
        if set(actual) != declared | {MANIFEST}:
            raise ValueError('package membership differs from manifest')
        launcher, _ = _launcher(manifest['platform'])
        required = {launcher, 'game/workflow.json', 'engine/bin/' + PLATFORMS[manifest['platform']]}
        if not required <= declared or manifest.get('launcher') != launcher:
            raise ValueError('package lacks platform launcher, project, or engine')
        for record in records:
            target = actual[record['path']]
            if target.stat().st_size != record['bytes'] or _sha256(target) != record['sha256']:
                raise ValueError(f"package hash/size mismatch: {record['path']}")
            count += 1
    except (OSError, ValueError, KeyError, TypeError) as error:
        diagnostics.append(dict(severity='error', code='package.invalid', path=str(path), message=str(error)))
    return dict(ok=not diagnostics, files=count, diagnostics=diagnostics)
