"""Candidate sprite import and lossless PCM WAV inspection/trimming.

Animation documents still require the authoritative engine validation gate.
Audio operations preserve sample bytes, channels, rate, and bit depth; no
resampling, codec conversion, or loudness normalization is implied.
"""
from __future__ import annotations

import copy
import hashlib
import math
import os
from pathlib import Path, PurePosixPath
import tempfile
import wave

from .assets import png_size


def _integer(value, name, minimum=0, maximum=None):
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f'invalid {name}')
    return value


def _regular_source(path):
    path = Path(path).absolute()
    if path.resolve() != path or not path.is_file():
        raise ValueError('source must be a regular file without symlinks or traversal')
    return path


def animation_candidate(image: Path, *, document_id: str, image_reference: str,
                        frame_width: int, frame_height: int, clips: list[dict],
                        margin: int = 0, spacing: int = 0, title: str | None = None) -> dict:
    """Derive an existing PNG's exact grid; return a detached anim candidate.

    image_reference is relative to the future animation document, not to the
    invoking process. The caller chooses placement and submits the returned
    document through validate/stage; this function writes no project files.
    """
    image = _regular_source(image)
    if not isinstance(document_id, str) or not document_id:
        raise ValueError('document_id must be a nonempty string')
    if (not isinstance(image_reference, str) or not image_reference
            or PurePosixPath(image_reference).is_absolute() or '\\' in image_reference
            or ':' in image_reference or '\x00' in image_reference):
        raise ValueError('image_reference must be a relative POSIX asset path')
    _integer(frame_width, 'frame_width', 1, 1024)
    _integer(frame_height, 'frame_height', 1, 1024)
    _integer(margin, 'margin')
    _integer(spacing, 'spacing')
    width, height = png_size(image)
    usable_width, usable_height = width - 2 * margin + spacing, height - 2 * margin + spacing
    if (usable_width <= 0 or usable_height <= 0
            or usable_width % (frame_width + spacing) or usable_height % (frame_height + spacing)):
        raise ValueError('PNG dimensions do not exactly fit the declared frame grid')
    columns, rows = usable_width // (frame_width + spacing), usable_height // (frame_height + spacing)
    _integer(columns, 'columns', 1, 256)
    _integer(rows, 'rows', 1, 256)
    if not isinstance(clips, list) or not 1 <= len(clips) <= 32:
        raise ValueError('clips must contain 1..32 entries')
    # Constructor guards prevent lossy input handling. The VM remains the
    # semantic authority for IDs, ordering, and cross-document references.
    for clip in clips:
        if not isinstance(clip, dict) or set(clip) - {'id', 'title', 'frames', 'fps', 'loop', 'events'}:
            raise ValueError('clip must contain only animation schema fields')
        if not isinstance(clip.get('id'), str) or not clip['id']:
            raise ValueError('clip requires an id')
        frames = clip.get('frames')
        if not isinstance(frames, list) or not 1 <= len(frames) <= 512:
            raise ValueError('clip requires 1..512 frames')
        for frame in frames:
            _integer(frame, 'sheet frame', 0, columns * rows - 1)
        fps = clip.get('fps')
        if type(fps) not in (int, float) or not math.isfinite(fps) or not .1 <= fps <= 120:
            raise ValueError('clip fps must be between 0.1 and 120')
        if 'loop' in clip and type(clip['loop']) is not bool:
            raise ValueError('clip loop must be boolean')
        if 'title' in clip and not isinstance(clip['title'], str):
            raise ValueError('clip title must be a string')
        events = clip.get('events', [])
        if not isinstance(events, list) or len(events) > 32:
            raise ValueError('clip events must contain at most 32 entries')
        for event in events:
            if not isinstance(event, dict) or set(event) != {'frame', 'name'} or not isinstance(event['name'], str):
                raise ValueError('event requires frame and name only')
            _integer(event['frame'], 'clip event frame', 0, len(frames) - 1)
    result = dict(schema='eve.rpgc.anim', version=1, id=document_id, image=image_reference,
                  frameWidth=frame_width, frameHeight=frame_height, columns=columns, rows=rows,
                  margin=margin, spacing=spacing, clips=copy.deepcopy(clips))
    if title is not None:
        if not isinstance(title, str):
            raise ValueError('title must be a string')
        result['title'] = title
    return result


def inspect_wav(path: Path) -> dict:
    """Inspect uncompressed integer PCM (8/16/24/32-bit), detecting truncation."""
    path = _regular_source(path)
    try:
        with wave.open(str(path), 'rb') as reader:
            channels, width, rate, frames, compression, _ = reader.getparams()
            if compression != 'NONE' or width not in (1, 2, 3, 4):
                raise ValueError('only integer PCM WAV with 8/16/24/32-bit samples is supported')
            expected, actual = frames * channels * width, 0
            while True:
                block = reader.readframes(65536)
                if not block:
                    break
                actual += len(block)
            if actual != expected:
                raise ValueError(f'truncated or misaligned PCM data: expected {expected} bytes, found {actual}')
    except (wave.Error, EOFError) as error:
        raise ValueError(f'invalid PCM WAV: {error}') from error
    return dict(ok=True, path=str(path), format='pcm', channels=channels, sampleWidth=width,
                bitsPerSample=width * 8, sampleRate=rate, frames=frames,
                durationSeconds=frames / rate, dataBytes=actual,
                sampleEncoding='unsigned' if width == 1 else 'signed-little-endian')


def trim_wav(source: Path, output: Path, start_frame: int, end_frame: int,
             *, project_root: Path | None = None) -> dict:
    """Copy the exact half-open sample-frame interval into a new PCM WAV.

    No overwrite, no sample conversion. WAV ancillary metadata is not copied.
    With an explicit/discovered project root, output must be external or under
    top-level dist/build. Discovery checks both source and destination parents.
    """
    source = _regular_source(source)
    output = Path(output).absolute()
    if output.resolve() != output or output.exists() or output.is_symlink():
        raise ValueError('output must be a new path without symlinks or traversal')
    if not output.parent.is_dir():
        raise ValueError('output parent directory must exist')
    roots = {Path(project_root).resolve()} if project_root is not None else set()
    for path in (source, output):
        for parent in path.parents:
            if (parent / 'workflow.json').is_file():
                roots.add(parent)
                break
    for root in roots:
        if output.is_relative_to(root) and output.relative_to(root).parts[0] not in {'dist', 'build'}:
            raise ValueError('audio output must be external to the project or under top-level dist/build')
    metadata = inspect_wav(source)
    _integer(start_frame, 'start_frame')
    _integer(end_frame, 'end_frame', 1)
    if not start_frame < end_frame <= metadata['frames']:
        raise ValueError('require 0 <= start_frame < end_frame <= source frames')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.rpgc-audio-', suffix='.tmp', delete=False) as handle:
            temporary = Path(handle.name)
        with wave.open(str(source), 'rb') as reader, wave.open(str(temporary), 'wb') as writer:
            writer.setparams(reader.getparams())
            reader.setpos(start_frame)
            remaining = end_frame - start_frame
            while remaining:
                count = min(remaining, 65536)
                data = reader.readframes(count)
                if len(data) != count * metadata['channels'] * metadata['sampleWidth']:
                    raise ValueError('source changed or truncated during trim')
                writer.writeframesraw(data)
                remaining -= count
        # Hard-link publication is atomic and fails if destination now exists.
        os.link(temporary, output)
    except (wave.Error, EOFError) as error:
        raise ValueError(f'invalid PCM WAV: {error}') from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    result = inspect_wav(output)
    result.update(source=str(source), startFrame=start_frame, endFrame=end_frame,
                  sha256=hashlib.sha256(output.read_bytes()).hexdigest())
    return result
