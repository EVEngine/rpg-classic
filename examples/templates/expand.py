#!/usr/bin/env python3
"""Print a template candidate + provenance; never write game content.

python3 examples/templates/expand.py > /tmp/potion-template-candidate.json
The changeSet member is accepted by the existing changes/check candidate gate.
Persist the sidecar only after accepting the validated candidate externally.
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
from rpgc_toolkit.project import read_json
from rpgc_toolkit.templates import expand_template, plan_instances


def main():
    library = read_json(Path(__file__).with_name('potion-library.json'))
    instance = expand_template(library, 'potion.development', 'potion.template-example',
                               {'name': '模板开发药'}, {'/value': 18})
    instance['path'] = 'content/items/potion.template-example.json'
    instance['sidecar']['path'] = instance['path']
    print(json.dumps({'ok': True, 'validated': False, 'applied': False, 'conflicts': [],
                      'instances': [instance], 'changeSet': plan_instances(ROOT, [instance])},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
