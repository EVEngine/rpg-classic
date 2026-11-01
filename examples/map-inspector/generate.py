#!/usr/bin/env python3
"""Generate good/bad map-inspector candidates; source maps/assets stay unchanged.

Requires the real SDK. Output is a NEW directory containing two change sets,
terrain rules, object provenance and native validation evidence. All 47 masks
use existing complete textures, not invented directional transition artwork.
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
from rpgc_toolkit.project import Project, fingerprint, read_json, inside
from rpgc_toolkit.runtime import run_headless
from rpgc_toolkit.terrain import BLOB_MASKS, autotile_map
from rpgc_toolkit.templates import instantiate_object_group
from rpgc_toolkit.map_qa import inspect_maps

MAP_PATH = 'content/maps/village-outskirts.json'
MAP_ID = 'village-outskirts'
SAND_NAME = 'Overworld - Terrain 2 - Flat 256x128#17'

NATIVE_SOURCE = r'''
import { RpgcNavigation } from "game:/lib/rpgc_navigation.nut"
import { RpgcTilemap } from "game:/lib/rpgc_tilemap.nut"
import { RpgcMapQA } from "game:/lib/rpgc_map_qa.nut"
local native=RpgcNavigation.load("village-outskirts");
local map=native.map;local layer=native.layer;local pf=native.pathfinder;
local spawnIndex=map.findObjectByName("spawn");
if(spawnIndex<0)throw "demo requires authored spawn";
local sx=layer.worldToTileX(map.getObjectX(spawnIndex),map.getObjectY(spawnIndex));
local sy=layer.worldToTileY(map.getObjectX(spawnIndex),map.getObjectY(spawnIndex));
local occupied={};
for(local i=0;i<map.getObjectCount();i+=1){
    local x=layer.worldToTileX(map.getObjectX(i),map.getObjectY(i));
    local y=layer.worldToTileY(map.getObjectX(i),map.getObjectY(i));
    occupied[x+","+y]<-true;
}
local best=null;local score=100000;local blocked=null;
for(local y=0;y<layer.getMapHeight();y+=1) for(local x=0;x<layer.getMapWidth();x+=1){
    if(blocked==null && !pf.isWalkable(x,y))blocked=[x,y];
    if(x<2 || y<2 || x>=layer.getMapWidth()-2 || y>=layer.getMapHeight()-2 || ((x+","+y) in occupied))continue;
    local valid=true;
    for(local dy=-2;dy<=2;dy+=1) for(local dx=-2;dx<=2;dx+=1) if(!pf.isWalkable(x+dx,y+dy))valid=false;
    if(!valid || !RpgcMapQA.reachable(pf,sx,sy,x,y))continue;
    local distance=(x-sx)*(x-sx)+(y-sy)*(y-sy);
    if(distance<score){score=distance;best=[x,y];}
}
if(best==null || blocked==null)throw "no native-confirmed demo patch or blocked landing";
local atlas=RpgcJson.parse(eve.Filesystem().readText("content/tilesets/sbs-overworld.json"));
if(!atlas.ok)throw "atlas unavailable";
RpgcToolkitResult <- RpgcJson.encodeCompact({ok=true,spawn=[sx,sy],patchCenter=best,blockedLanding=blocked,
    objectWorld=[layer.tileToWorldX(best[0],best[1])+layer.getTileWidth()*0.5,
                 layer.tileToWorldY(best[0],best[1])+layer.getTileHeight()*0.5],
    tiles=RpgcTilemap.tilesOf(atlas.value),rules=RpgcNavigation.atlasRules("content/maps/village-outskirts.json")});
'''


def make_candidates(root, evidence):
    """Transform only after receiving native metadata; no Python geometry."""
    root = Path(root).resolve()
    original = read_json(root / MAP_PATH)
    candidates = [tile for tile in evidence['tiles'] if tile['name'] == SAND_NAME and tile['walkable'] is True]
    if len(candidates) != 1:
        raise ValueError('expected named, explicitly walkable sand tile in authoritative metadata')
    sand = candidates[0]['gid']
    if not evidence['rules'].get(str(sand), {}).get('walkable'):
        raise ValueError('navigation metadata does not admit the chosen sand GID')
    ground = next(layer for layer in original['layers'] if layer['id'] == 'terrain')
    lower = sorted(set(ground['data']) - {0, sand})
    if not lower or any(not evidence['rules'].get(str(gid), {}).get('walkable') for gid in lower):
        raise ValueError('demo expects existing nonzero floor GIDs to be explicitly walkable')
    grass = max(lower, key=lambda gid: (ground['data'].count(gid), -gid))
    rules = {'format': 'rpgc.terrain-rules', 'version': 2, 'mode': 'transition8',
             'terrains': {'sand': {'terrainGids': [sand], 'masks': {str(m): sand for m in BLOB_MASKS}},
                          'ground': {'terrainGids': lower, 'masks': {str(m): grass for m in BLOB_MASKS}}},
             'priority': ['sand', 'ground']}
    cx, cy = evidence['patchCenter']
    cells = [[x, y] for y in range(cy-1, cy+2) for x in range(cx-1, cx+2)]
    painted = autotile_map(original, 'terrain', cells, rules, terrain_id='sand', seed=2026)
    sx, sy = evidence['spawn']; wx, wy = evidence['objectWorld']
    template = {'format': 'rpgc.object-group-template', 'version': 1, 'id': 'inspector.portal', 'revision': 1,
                'coordinateSpace': 'world', 'objects': [{'name': 'portal', 'type': 'portal', 'x': wx, 'y': wy,
                    'properties': [{'name': name, 'type': 'string', 'value': value} for name, value in
                                   [('targetMap', MAP_ID), ('targetX', str(sx)), ('targetY', str(sy)),
                                    ('facingX', '0'), ('facingY', '1')]]}], 'nameReferences': []}
    expanded = instantiate_object_group(root, MAP_PATH, 'actors', template, 'inspector.portal.demo', {'portal': 'inspector_portal'})
    good = expanded['changeSet']
    document = good['changes'][0]['document']
    for index, layer in enumerate(document['layers']):
        if layer['id'] == 'terrain':
            document['layers'][index] = deepcopy(next(v for v in painted['layers'] if v['id'] == 'terrain'))
    bad = deepcopy(good)
    bx, by = evidence['blockedLanding']
    for layer in bad['changes'][0]['document']['layers']:
        for obj in layer.get('objects', []):
            if obj['name'] == 'inspector_portal':
                for prop in obj['properties']:
                    if prop['name'] == 'targetX': prop['value'] = str(bx)
                    if prop['name'] == 'targetY': prop['value'] = str(by)
    return {'good': good, 'bad': bad, 'rules': rules, 'objectTemplate': template,
            'sidecar': expanded['instances'][0]['sidecar'],
            'summary': {'mapId': MAP_ID, 'sourceFingerprint': fingerprint(original), 'paintedCells': cells,
                        'sandGid': sand, 'sandName': SAND_NAME, 'sandWalkable': True, 'groundGid': grass,
                        'nativeObjectWorld': [wx, wy], 'nativeBlockedLanding': [bx, by],
                        'dedicatedTransitionArtwork': False}}


def generate(binary, root, output):
    root, output = Path(root).resolve(), Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('output must be a new directory; existing artifacts are never overwritten')
    for spec in Project(root).kinds.values():
        if output.resolve().is_relative_to(inside(root, spec['directory'])):
            raise ValueError('output must be outside all content directories')
    original = (root / MAP_PATH).read_bytes()
    evidence = run_headless(binary, root, NATIVE_SOURCE)
    if not evidence.get('ok'):
        raise ValueError('native demo metadata query failed: ' + json.dumps(evidence))
    generated = make_candidates(root, evidence)
    good_qa = inspect_maps(binary, root, MAP_ID, changes=generated['good'])
    bad_qa = inspect_maps(binary, root, MAP_ID, changes=generated['bad'])
    if not good_qa.get('ok') or not good_qa.get('gate', {}).get('ok'):
        raise ValueError('positive candidate failed native validation/QA: ' + json.dumps(good_qa.get('diagnostics')))
    codes = [d['code'] for d in bad_qa.get('diagnostics', [])]
    if not bad_qa.get('gate', {}).get('ok') or bad_qa.get('ok') or 'map-qa.portal-landing' not in codes:
        raise ValueError('negative candidate must pass schema gate and fail native portal landing QA')
    if (root / MAP_PATH).read_bytes() != original:
        raise ValueError('source map changed during generation; retry')
    summary = dict(generated['summary'], good={'gate': True, 'qa': True},
                   bad={'gate': True, 'qa': False, 'diagnostics': bad_qa['diagnostics']}, applied=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix='.map-inspector-', dir=output.parent))
    try:
        artifacts = {'good.change-set.json': generated['good'], 'bad-landing.change-set.json': generated['bad'],
                     'terrain.rules.json': generated['rules'], 'object.template.json': generated['objectTemplate'],
                     'object.source.json': generated['sidecar'], 'evidence.json': summary}
        for filename, value in artifacts.items():
            (scratch / filename).write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)+'\n', encoding='utf-8')
        if output.exists(): raise ValueError('output appeared while generating; refusing overwrite')
        scratch.rename(output)
    finally:
        if scratch.exists(): shutil.rmtree(scratch)
    return {'ok': True, 'applied': False, 'output': str(output), **summary}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--eve', required=True)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        result = generate(args.eve, args.root, args.output)
    except (ValueError, OSError) as error:
        result = {'ok': False, 'error': str(error)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['ok'] else 1


if __name__ == '__main__': raise SystemExit(main())
