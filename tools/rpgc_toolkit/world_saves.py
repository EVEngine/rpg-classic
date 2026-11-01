"""World-save CLI adapters and explicit, lossless content-version migrations.

The VM owns snapshot validation/checksums and all gameplay rules. Python only
orchestrates candidate transformations and exclusive output publication.
"""
from copy import deepcopy
import json
import math
import os
from pathlib import Path
import tempfile

from .runtime import run_headless

MAX_EXACT = 16777215
IMPORT = 'import { RpgcSave } from "game:/lib/rpgc_save.nut"\n'


def _guard(value, depth=0):
    if depth > 48:
        raise ValueError('save nesting exceeds 48 levels')
    if value is None or type(value) in (str, bool):
        return
    if type(value) in (int, float):
        if not math.isfinite(value) or abs(value) > MAX_EXACT:
            raise ValueError('save number outside exact VM range')
        return
    if isinstance(value, list):
        if len(value) > 65536:
            raise ValueError('save array budget exceeded')
        for child in value:
            _guard(child, depth + 1)
        return
    if isinstance(value, dict):
        if len(value) > 65536 or any(not isinstance(key, str) for key in value):
            raise ValueError('invalid save object keys/budget')
        for child in value.values():
            _guard(child, depth + 1)
        return
    raise ValueError('save must contain only JSON values')


def _literal(document):
    _guard(document)
    raw = json.dumps(document, ensure_ascii=False, allow_nan=False)
    if len(raw.encode('utf-8')) > 8 * 1024 * 1024:
        raise ValueError('save input exceeds 8 MiB')
    return json.dumps(raw, ensure_ascii=False)


def _run(binary, root, value, expression, timeout):
    source = IMPORT + 'local input=RpgcJson.parse(' + _literal(value) + ').value;\n'
    source += 'RpgcToolkitResult <- RpgcJson.encodeCompact(' + expression + ');\n'
    return run_headless(binary, root, source, timeout)


def check_world(binary, root, snapshot, timeout=120):
    result = _run(binary, root, snapshot, 'RpgcSave.restore(input)', timeout)
    result['applied'] = False
    result['nativePlacementValidated'] = False
    return result


def content_manifest(binary, root, timeout=120):
    return _run(binary, root, {}, 'RpgcSave.contentManifest()', timeout)


def capture_world(binary, root, request, timeout=120):
    """Capture an explicit world context plus a legacy inventory-v1 document."""
    required = {'world', 'inventory', 'partyId', 'locale', 'inputSequence'}
    if not isinstance(request, dict) or set(request) - (required | {'context'}) or not required <= set(request):
        raise ValueError('capture requires world, inventory, partyId, locale, inputSequence; optional context')
    _guard(request)
    source = IMPORT + '''import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"
function captureRequest(input) {
    local config=RpgcItems.loadProject(); if(!config.ok)return config;
    local inventory=RpgcSave._inventory(input.inventory,config.value); if(!inventory.ok)return inventory;
    local world=RpgcWorldState.create(input.world); if(!world.ok)return world;
    if(world.value.bag!=0)return RpgcSave.fail("capture world.bag must be 0; inventory is the only bag source");
    world.value.bag=inventory.value.bag;
    local context=("context" in input)?input.context:0;
    return RpgcSave.capture(world.value,inventory.value.equipment,
        {partyId=input.partyId,locale=input.locale,inputSequence=input.inputSequence},context);
}
RpgcToolkitResult <- RpgcJson.encodeCompact(captureRequest(RpgcJson.parse(PAYLOAD).value));
'''.replace('PAYLOAD', _literal(request))
    result = run_headless(binary, root, source, timeout)
    result['applied'] = False
    result['nativePlacementValidated'] = False
    return result


def _mapping(value, name, unique=True):
    if not isinstance(value, dict) or any(not isinstance(k,str) or not k or not isinstance(v,str) or not v for k,v in value.items()):
        raise ValueError(name + ' requires nonempty string mappings')
    if unique and len(set(value.values())) != len(value):
        raise ValueError(name + ' mappings must not merge identities')
    return value


def _rename_keys(table, mapping, name):
    if not isinstance(table, dict):
        raise ValueError(name + ' must be an object')
    result = {}
    for key, value in table.items():
        new = mapping.get(key, key)
        if new in result:
            raise ValueError(name + ' identity collision: ' + new)
        result[new] = value
    return result


def prepare_migration(snapshot, plan):
    """Pure candidate preparation; not a replacement for migrate_world's VM gates."""
    if not isinstance(snapshot, dict) or snapshot.get('format') != 'eve.rpgc.world.snapshot' or type(snapshot.get('version')) is not int or snapshot['version'] != 1:
        raise ValueError('only world snapshot version 1 is supported; future versions are refused')
    if not isinstance(plan,dict) or set(plan) != {'format','version','steps'} or plan['format'] != 'rpgc.world-migration-plan' or type(plan['version']) is not int or plan['version'] != 1:
        raise ValueError('expected rpgc.world-migration-plan version 1')
    steps=plan['steps']
    if not isinstance(steps,list) or not 1 <= len(steps) <= 32:
        raise ValueError('migration requires a continuous chain of 1..32 steps')
    _guard(snapshot)
    _guard(plan)
    payload=snapshot.get('payload')
    if not isinstance(payload,dict) or not isinstance(payload.get('world'),dict) or not isinstance(payload.get('inventory'),dict):
        raise ValueError('migration requires a world/inventory payload')
    world=payload['world']
    if not isinstance(world.get('mapId'),str) or any(not isinstance(world.get(key),dict) for key in ('quests','consumed','completedEvents')):
        raise ValueError('migration requires mapId and state identity tables')
    for field in ('stacks','equipped'):
        rows=payload['inventory'].get(field)
        if not isinstance(rows,list) or any(not isinstance(row,dict) or not isinstance(row.get('itemId'),str) for row in rows):
            raise ValueError('migration requires valid inventory rows')
    result=deepcopy(snapshot)
    result.pop('checksum',None)
    history=[]
    seen_ids=set()
    seen_content=[deepcopy(result.get('content'))]
    for step in steps:
        required={'id','fromContent','toContent'}
        allowed=required|{'maps','items','events','objects'}
        if not isinstance(step,dict) or not required<=set(step) or set(step)-allowed:
            raise ValueError('invalid migration step fields')
        identity=step['id']
        if not isinstance(identity,str) or not identity or identity in seen_ids:
            raise ValueError('migration step IDs must be unique and nonempty')
        seen_ids.add(identity)
        before=_mapping(step['fromContent'],'fromContent',unique=False)
        after=_mapping(step['toContent'],'toContent',unique=False)
        # Content checksums are allowed to coincide for different definitions.
        if result.get('content') != before:
            raise ValueError('migration chain has a gap or stale source content: ' + identity)
        if after in seen_content:
            raise ValueError('migration chain repeats a content revision')
        seen_content.append(deepcopy(after))
        maps=_mapping(step.get('maps',{}),'maps')
        items=_mapping(step.get('items',{}),'items')
        events=_mapping(step.get('events',{}),'events')
        objects=_mapping(step.get('objects',{}),'objects')
        for name, mapping, kind in [('maps',maps,'map'),('items',items,'item'),('events',events,'event')]:
            for old,new in mapping.items():
                if kind+'/'+old not in before or kind+'/'+new not in after:
                    raise ValueError(name+' mapping must name source and target definitions')
        world=result['payload']['world']
        # Never silently change objective counts, definitions or claimed semantics.
        for quest in world['quests']:
            key='quest/'+quest
            if key not in before or before[key] != after.get(key):
                raise ValueError('saved quest definition changed; explicit quest migration adapter required: '+quest)
        world['mapId']=maps.get(world['mapId'],world['mapId'])
        consumed={}
        for old,value in world['consumed'].items():
            if '/' not in old:
                raise ValueError('consumed identity must be mapId/objectName')
            map_id,object_name=old.split('/',1)
            new=objects.get(old,maps.get(map_id,map_id)+'/'+object_name)
            if '/' not in new or new in consumed:
                raise ValueError('consumed object identity collision or malformed mapping')
            consumed[new]=value
        world['consumed']=consumed
        world['completedEvents']=_rename_keys(world['completedEvents'],events,'completedEvents')
        inventory=result['payload']['inventory']
        for field in ('stacks','equipped'):
            for row in inventory[field]:
                row['itemId']=items.get(row['itemId'],row['itemId'])
        result['content']=deepcopy(after)
        history.append({'id':identity,'maps':maps,'items':items,'events':events,'objects':objects})
    return result,deepcopy(history)


def migrate_world(binary,root,snapshot,plan,timeout=120):
    verified=_run(binary,root,snapshot,'RpgcSave.verifyEnvelope(input)',timeout)
    if not verified.get('ok'):
        verified['applied']=False
        return verified
    body,history=prepare_migration(snapshot,plan)
    result=_run(binary,root,body,'''(function() {
        local sealed=RpgcSave.seal(input); if(!sealed.ok)return sealed;
        local restored=RpgcSave.restore(sealed.value); if(!restored.ok)return restored;
        return {ok=true,diagnostics=[],value={status="ready",snapshot=sealed.value}};
    })()''',timeout)
    result['applied']=False
    result['nativePlacementValidated']=False
    result['migrations']=history
    return result


def publish_new(path,snapshot):
    """Publish a new candidate only; never overwrite an existing or historical save."""
    destination=Path(path)
    payload=(json.dumps(snapshot,ensure_ascii=False,allow_nan=False,indent=2)+'\n').encode('utf-8')
    temporary=None
    try:
        with tempfile.NamedTemporaryFile(dir=destination.parent,prefix='.rpgc-world-',delete=False) as file:
            temporary=Path(file.name)
            file.write(payload); file.flush(); os.fsync(file.fileno())
        os.link(temporary,destination)
        # Link publication is exclusive. A later directory-sync error is reported,
        # never followed by deleting an output another reader might already use.
        if os.name == 'posix':
            fd=os.open(destination.parent,os.O_RDONLY)
            try: os.fsync(fd)
            finally: os.close(fd)
    finally:
        if temporary is not None:temporary.unlink(missing_ok=True)
