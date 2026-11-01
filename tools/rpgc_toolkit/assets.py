"""Read-only resource checks, separate from the engine's content validation gate."""
from __future__ import annotations

import hashlib
from pathlib import Path
import struct

from .project import Project


def _inside(root: Path, path: Path) -> Path:
    root = root.resolve()
    relative = path.relative_to(root)
    current = root
    for part in relative.parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"symbolic links are not supported: {relative}")
    resolved = path.resolve()
    if not resolved.is_relative_to(root):
        raise ValueError(f"resource escapes project: {relative}")
    return resolved


def png_size(path: Path) -> tuple[int, int]:
    """Read PNG IHDR dimensions; this is not a complete image decoder."""
    with path.open('rb') as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b'\x89PNG\r\n\x1a\n' or header[8:16] != b'\0\0\0\rIHDR':
        raise ValueError('invalid PNG header')
    width, height = struct.unpack('>II', header[16:24])
    if not width or not height:
        raise ValueError('PNG dimensions must be positive')
    return width, height


def audit_assets(root: Path) -> dict:
    """Audit declared tileset/animation images and battle backgrounds.

    Paths follow the existing document-relative asset convention. Arbitrary
    strings in effect.extra are opaque metadata, not presumed file references.
    No image decoding dependency or engine process is required.
    """
    root = Path(root).resolve()
    diagnostics, assets = [], {}

    def issue(code, path, message, severity='error'):
        diagnostics.append(dict(severity=severity, code=code, path=path, message=message))

    try:
        project = Project(root)
        entries = project.documents()
    except (OSError, ValueError, KeyError, TypeError) as error:
        issue('asset.project', 'workflow.json', str(error))
        return dict(ok=False, assets=[], diagnostics=diagnostics)
    for kind, field in [('tileset', 'image'), ('anim', 'image'), ('battle', 'background')]:
        spec = project.kinds.get(kind)
        if not spec:
            continue
        for entry in (e for e in entries if e['kind'] == kind):
            source = root / entry['path']
            where = entry['path']
            try:
                _inside(root, source)
                doc = entry['document']
                reference = doc.get(field)
                if reference is None and kind == 'battle':
                    continue
                if not isinstance(reference, str) or not reference:
                    raise ValueError(f'{field} must be a nonempty path')
                if Path(reference).is_absolute() or '\\' in reference:
                    raise ValueError('resource must use a relative POSIX path')
                target = _inside(root, source.parent / reference)
                asset_path = target.relative_to(root).as_posix()
                if not target.is_file():
                    issue('asset.missing', where + '/' + field, asset_path)
                    continue
                if asset_path not in assets:
                    data = target.read_bytes()
                    assets[asset_path] = dict(path=asset_path, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
                info = assets[asset_path]
                if target.suffix.lower() != '.png':
                    issue('asset.dimensions-unchecked', where + '/' + field,
                          'Only PNG dimensions are inspected', 'warning')
                    continue
                width, height = png_size(target)
                info.update(width=width, height=height)
                if kind == 'anim':
                    margin, spacing = doc.get('margin', 0), doc.get('spacing', 0)
                    expected = (2 * margin + doc['columns'] * doc['frameWidth'] + (doc['columns'] - 1) * spacing,
                                2 * margin + doc['rows'] * doc['frameHeight'] + (doc['rows'] - 1) * spacing)
                    if (width, height) != expected:
                        issue('asset.dimensions', where + '/' + field,
                              f'PNG is {width}x{height}; declared animation grid is {expected[0]}x{expected[1]}')
                elif kind == 'tileset':
                    if doc.get('version') == 2 and width != doc['layout']['width']:
                        issue('asset.dimensions', where + '/' + field,
                              f"PNG width {width} differs from layout.width {doc['layout']['width']}")
                    for index, tile in enumerate(doc.get('tiles', [])):
                        if 'region' in tile:
                            x, y, w, h = tile['region']
                            if min(x, y) < 0 or min(w, h) <= 0 or x + w > width or y + h > height:
                                issue('asset.region-outside-image', f'{where}/tiles/{index}/region',
                                      f'region exceeds {width}x{height} image')
            except (OSError, ValueError, KeyError, TypeError) as error:
                issue('asset.read', where, str(error))
    return dict(ok=not any(d['severity'] == 'error' for d in diagnostics),
                assets=[assets[k] for k in sorted(assets)], diagnostics=diagnostics)
