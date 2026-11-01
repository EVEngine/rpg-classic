"""Lossless inventory-save ID migration candidates and real VM restore checks."""
from copy import deepcopy
import json

from .project import fingerprint, _equal
from .runtime import run_headless


def migrate_inventory(snapshot, item_ids=None, equipment_slots=None, expected=None):
    """Remap IDs without merging stacks, changing quantities, or changing version.

    Version 1 is the only runtime-supported format. This intentionally refuses
    invented upgrade chains; future versions need an explicit runtime adapter.
    """
    if not isinstance(snapshot,dict) or snapshot.get('format')!='eve.rpgc.items.snapshot' or type(snapshot.get('version')) is not int or snapshot['version']!=1:
        raise ValueError('expected eve.rpgc.items.snapshot version 1')
    if expected is not None and fingerprint(snapshot)!=expected:
        raise ValueError('stale save fingerprint')
    item_ids={} if item_ids is None else item_ids
    equipment_slots={} if equipment_slots is None else equipment_slots
    for mapping in (item_ids,equipment_slots):
        if not isinstance(mapping,dict) or any(not isinstance(k,str) or not k or not isinstance(v,str) or not v for k,v in mapping.items()):
            raise ValueError('save ID mappings require nonempty string keys and values')
    result=deepcopy(snapshot)
    count=result.get('slotCount')
    if type(count) is not int or not 1<=count<=65536:
        raise ValueError('save slotCount must be 1..65536')
    used_bag,used_equipment=set(),set()
    for key in ('stacks','equipped'):
        rows=result.get(key)
        if not isinstance(rows,list): raise ValueError(f'save {key} must be an array')
        for row in rows:
            if not isinstance(row,dict) or not isinstance(row.get('itemId'),str) or not row['itemId']:
                raise ValueError(f'invalid save {key} row')
            row['itemId']=item_ids.get(row['itemId'],row['itemId'])
            if key=='stacks':
                index,quantity=row.get('bagSlot'),row.get('quantity')
                if type(index) is not int or not 0<=index<count or index in used_bag or type(quantity) is not int or not 1<=quantity<=16777216:
                    raise ValueError('invalid/duplicate bag slot or quantity outside exact VM integer range 1..16777216')
                used_bag.add(index)
            else:
                slot=row.get('slot')
                if not isinstance(slot,str) or not slot: raise ValueError('equipment slot must be a string')
                row['slot']=equipment_slots.get(slot,slot)
                if row['slot'] in used_equipment: raise ValueError('equipment slot mapping collides')
                used_equipment.add(row['slot'])
    return result


def check_inventory(binary,root,snapshot,timeout=120):
    # Normalize through the migration input guard before invoking the runtime;
    # duplicate slots must not be silently overwritten by restore().
    candidate=migrate_inventory(snapshot)
    text=json.dumps(json.dumps(candidate,ensure_ascii=False,allow_nan=False),ensure_ascii=False)
    source='''import { RpgcItems } from "game:/lib/rpgc_items.nut"
local loaded = RpgcItems.loadProject();
local report = {ok=false, diagnostics=[]};
if (!loaded.ok) report.diagnostics = loaded.diagnostics;
else {
    local restored = RpgcItems.restore('''+text+''', loaded.value);
    report.ok = restored.ok;
    report.diagnostics = restored.diagnostics;
    if (restored.ok) report.snapshot <- RpgcItems.snapshot(restored.value.bag, restored.value.equipment);
}
RpgcToolkitResult <- RpgcJson.encodeCompact(report);
'''
    report=run_headless(binary,root,source,timeout)
    report['applied']=False
    if report.get('ok'):
        # Preserve unknown extension fields in candidate but reveal what this
        # runtime actually persists, instead of claiming a lossless round trip.
        restored=report['snapshot']
        report['roundTripEqual']=_equal(restored,candidate)
        losses=[]
        for field in ('format','version','id','slotCount','maxWeight','maxVolume','capacityPolicy'):
            if field in candidate and not _equal(candidate[field],restored.get(field)):
                losses.append('/'+field)
        for field,key in (('stacks','bagSlot'),('equipped','slot')):
            before={row[key]:row for row in candidate[field]}
            after={row[key]:row for row in restored[field]}
            core=('itemId','quantity') if field=='stacks' else ('itemId',)
            if before.keys()!=after.keys() or any(
                not _equal(before[k].get(f),after[k].get(f)) for k in before.keys() & after.keys() for f in core):
                losses.append('/'+field)
        if losses:
            report['ok']=False
            report['diagnostics'].append({'severity':'error','code':'save.roundtrip-loss',
                'path':','.join(losses),'message':'runtime restore changes persisted save data'})
        elif not report['roundTripEqual']:
            report['diagnostics'].append({'severity':'warning','code':'save.extensions-not-persisted',
                'path':'/','message':'runtime snapshot differs in extension fields or row ordering; inspect snapshot before replacing a save'})
        report['fingerprint']=fingerprint(restored)
    return report
