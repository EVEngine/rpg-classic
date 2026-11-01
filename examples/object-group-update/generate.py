#!/usr/bin/env python3
"""Build a disposable project with two object-group instances and update demos.

Requires a NEW --output directory and --eve. Original content is never edited.
The output sandbox is intentionally authored with the initial instances and a
manual coordinate edit, so both request files can be replayed directly:
  python3 tools/rpgc.py --root OUTPUT/sandbox toolkit template objects-update OUTPUT/clean.request.json
  python3 tools/rpgc.py --root OUTPUT/sandbox toolkit template objects-update OUTPUT/conflict.request.json
Clean output passes the authoritative gate; conflicts exclude the entire map.
"""
from __future__ import annotations
import argparse
from copy import deepcopy
import json
from pathlib import Path
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit import templates as toolkit
from rpgc_toolkit.changes import candidate_workspace
from rpgc_toolkit.project import Project, inside, fingerprint, read_json

PATH = 'content/maps/village-outskirts.json'


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)+'\n', encoding='utf-8')


def objects(document):
    return next(layer['objects'] for layer in document['layers'] if layer['id'] == 'actors')


def make_template(document):
    # Reuse an authored native-world position and known valid chest properties.
    source = deepcopy(next(obj for obj in objects(document) if obj['name'] == 'old_chest'))
    source['name'] = 'cache'
    retired = deepcopy(source); retired['name'] = 'retired'; retired['x'] += 128; retired['y'] += 64
    return {'format': 'rpgc.object-group-template', 'version': 1, 'id': 'demo.cache-group', 'revision': 1,
            'coordinateSpace': 'world', 'objects': [source, retired], 'nameReferences': []}


def generate(binary, root, output):
    root, output = Path(root).resolve(), Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('output must be a new directory')
    for spec in Project(root).kinds.values():
        if output.resolve().is_relative_to(inside(root, spec['directory'])):
            raise ValueError('output must be outside source content')
    source_bytes = (root / PATH).read_bytes()
    output.parent.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix='.object-group-example-', dir=output.parent))
    try:
        with candidate_workspace(root, []) as workspace:
            template = make_template(read_json(workspace / PATH)); records = []
            for prefix, offset in [('example.one', [0, 0]), ('example.two', [256, 0])]:
                report = toolkit.instantiate_object_group(workspace, PATH, 'actors', template, prefix,
                    {'cache': prefix+'.cache', 'retired': prefix+'.retired'}, offset)
                write(workspace / PATH, report['changeSet']['changes'][0]['document'])
                records.append({'path': PATH, 'sidecar': report['instances'][0]['sidecar'],
                                'nameMap': {'cache': prefix+'.cache', 'fresh': prefix+'.fresh'}})
            manual = read_json(workspace / PATH)
            edited = next(obj for obj in objects(manual) if obj['name'] == 'example.one.cache')
            edited['x'] += 16
            write(workspace / PATH, manual)
            baseline = (workspace / PATH).read_bytes()
            newer = deepcopy(template); newer['revision'] = 2
            next(p for p in newer['objects'][0]['properties'] if p['name'] == 'gold')['value'] = '50'
            added = deepcopy(newer['objects'][1]); added['name'] = 'fresh'; added['x'] += 64
            newer['objects'] = [newer['objects'][0], added]
            conflicting = deepcopy(newer); conflicting['objects'][0]['x'] += 32
            clean_request = {'templates': [newer], 'instances': records, 'previousTemplates': [template]}
            conflict_request = {'templates': [conflicting], 'instances': records, 'previousTemplates': [template]}
            clean = toolkit.update_object_groups(workspace, [newer], records, previous_templates=[template])
            conflict = toolkit.update_object_groups(workspace, [conflicting], records, previous_templates=[template])
            if not clean['ok'] or conflict['ok'] or conflict['changeSet']['changes']:
                raise ValueError('example update did not produce the expected clean/conflict distinction')
            gate = toolkit.check_templates(binary, workspace, clean)
            if not gate.get('ok'):
                raise ValueError('clean update candidate failed authoritative validation: '+json.dumps(gate))
            try:
                toolkit.check_templates(binary, workspace, conflict)
            except ValueError:
                pass
            else:
                raise ValueError('conflict candidate was not refused')
            if (workspace / PATH).read_bytes() != baseline:
                raise ValueError('update unexpectedly modified its source')
            if (root / PATH).read_bytes() != source_bytes:
                raise ValueError('original map changed during generation')
            shutil.copytree(workspace, scratch / 'sandbox')
            root_candidate = deepcopy(clean['changeSet'])
            root_candidate['changes'][0]['expect'] = fingerprint(read_json(root / PATH))
            artifacts = {'clean.request.json': clean_request, 'conflict.request.json': conflict_request,
                         'clean.report.json': clean, 'conflict.report.json': conflict,
                         'clean.change-set.json': clean['changeSet'], 'root.change-set.json': root_candidate,
                         'template.previous.json': template, 'template.current.json': newer,
                         'evidence.json': {'ok': True, 'appliedToOriginal': False, 'cleanGate': gate,
                                           'manualX': edited['x'], 'sameMapInstances': 2,
                                           'conflictCount': len(conflict['conflicts'])}}
            for filename, value in artifacts.items(): write(scratch / filename, value)
        if output.exists(): raise ValueError('output appeared during generation')
        scratch.rename(output)
    finally:
        if scratch.exists(): shutil.rmtree(scratch)
    return {'ok': True, 'appliedToOriginal': False, 'output': str(output), 'sandbox': str(output/'sandbox'),
            'cleanGate': True, 'conflictGate': 'refused', 'sameMapInstances': 2}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--eve', required=True)
    args = parser.parse_args()
    try: result = generate(args.eve, args.root, args.output)
    except (OSError, ValueError) as error: result = {'ok': False, 'error': str(error)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['ok'] else 1


if __name__ == '__main__': raise SystemExit(main())
