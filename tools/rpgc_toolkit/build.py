"""Deterministic source bundles; these are not standalone game executables."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import tempfile
import shutil
import zipfile

MANIFEST = 'RPGC-BUNDLE.json'
EXCLUDED_DIRS = {'.git', '.hg', '.svn', '__pycache__', '.pytest_cache', '.venv', 'node_modules', 'dist', 'build', 'extracted'}
EXCLUDED_NAMES = {'eve.log', 'imgui.ini', '.DS_Store', 'Thumbs.db'}


def _digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _safe_member(name: str) -> bool:
    if not isinstance(name, str) or not name or '\x00' in name:
        return False
    parts = PurePosixPath(name)
    return (not parts.is_absolute() and '..' not in parts.parts and '\\' not in name
            and ':' not in name and parts.as_posix() == name and name != '.')


def _manifest_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate manifest key: {key}')
        result[key] = value
    return result


def _zip_entry(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, (1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    return info


def build_bundle(root: Path, output: Path) -> dict:
    """Snapshot project files with reproducible metadata and a SHA-256 manifest.

    Never overwrites an existing output. Content validation is deliberately not
    implied: run the authoritative engine gate separately before distribution.
    Output must be outside the project or under its top-level dist/ or build/.
    """
    root, output = Path(root).resolve(), Path(output).absolute()
    if not (root / 'workflow.json').is_file():
        raise ValueError('source root must contain workflow.json')
    if output.exists() or output.is_symlink():
        raise ValueError('output already exists')
    if not output.parent.is_dir():
        raise ValueError('output parent directory must exist')
    if output.resolve() != output:
        raise ValueError('output path must not contain symlinks or traversal')
    if output.is_relative_to(root) and output.relative_to(root).parts[0] not in {'dist', 'build'}:
        raise ValueError('output must be outside the project or under top-level dist/ or build/')
    records, paths = [], []
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED_DIRS)
        for d in dirs:
            if (Path(directory) / d).is_symlink():
                raise ValueError(f'symbolic link in project: {Path(directory) / d}')
        for name in sorted(files):
            path = Path(directory) / name
            if (name in EXCLUDED_NAMES or name.endswith(('.pyc', '.tmp', '.log', '.baked.json'))
                    or (name.startswith('.rpgc-toolkit-') and name.endswith('.nut')) or path == output):
                continue
            if path.is_symlink() or not path.is_file():
                raise ValueError(f'non-regular project file: {path}')
            relative = path.relative_to(root).as_posix()
            if not _safe_member(relative):
                raise ValueError(f'unsafe source filename: {relative}')
            if relative == MANIFEST:
                raise ValueError(f'reserved project file: {MANIFEST}')
            paths.append((relative, path))
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.rpgc-', suffix='.tmp', delete=False) as handle:
            temporary = Path(handle.name)
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for relative, path in sorted(paths):
                data = path.read_bytes()
                records.append(dict(path=relative, bytes=len(data), sha256=_digest(data)))
                archive.writestr(_zip_entry(relative), data)
            manifest = dict(format='rpgc-source-bundle', version=1, validated=False, files=records)
            archive.writestr(_zip_entry(MANIFEST), json.dumps(manifest, sort_keys=True, ensure_ascii=False, indent=2).encode('utf-8') + b'\n')
        # Exclusive creation makes the no-overwrite guarantee hold even if a
        # concurrent process creates the requested destination during packing.
        created = False
        try:
            with output.open('xb') as target, temporary.open('rb') as source:
                created = True
                shutil.copyfileobj(source, target)
        except BaseException:
            if created:
                output.unlink(missing_ok=True)
            raise
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return dict(ok=True, kind='source-bundle', validated=False, path=str(output),
                sha256=_digest(output.read_bytes()), files=len(records))


def verify_bundle(path: Path) -> dict:
    """Verify member safety, exact manifest membership, sizes, and hashes."""
    diagnostics = []
    count = 0
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            if len(names) != len(set(names)):
                raise ValueError('duplicate ZIP members')
            for entry in archive.infolist():
                if not _safe_member(entry.filename) or entry.is_dir():
                    raise ValueError(f'unsafe ZIP member: {entry.filename}')
                if stat.S_ISLNK(entry.external_attr >> 16):
                    raise ValueError(f'symlink ZIP member: {entry.filename}')
            manifest = json.loads(archive.read(MANIFEST), object_pairs_hook=_manifest_pairs)
            if (not isinstance(manifest, dict) or manifest.get('format') != 'rpgc-source-bundle'
                    or type(manifest.get('version')) is not int or manifest['version'] != 1):
                raise ValueError('unsupported bundle manifest')
            records = manifest.get('files')
            if not isinstance(records, list):
                raise ValueError('manifest files must be an array')
            for record in records:
                if (not isinstance(record, dict) or not _safe_member(record.get('path'))
                        or type(record.get('bytes')) is not int or record['bytes'] < 0
                        or not isinstance(record.get('sha256'), str) or len(record['sha256']) != 64
                        or any(c not in '0123456789abcdef' for c in record['sha256'])):
                    raise ValueError('malformed manifest file record')
            paths = [r['path'] for r in records]
            if len(paths) != len(set(paths)) or set(names) != set(paths) | {MANIFEST} or MANIFEST in paths:
                raise ValueError('manifest membership mismatch')
            for record in records:
                data = archive.read(record['path'])
                if len(data) != record['bytes'] or _digest(data) != record['sha256']:
                    raise ValueError(f"hash/size mismatch: {record['path']}")
                count += 1
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        diagnostics.append(dict(severity='error', code='bundle.invalid', path=str(path), message=str(error)))
    return dict(ok=not diagnostics, files=count, diagnostics=diagnostics)
