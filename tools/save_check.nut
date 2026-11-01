import { RpgcSave } from "game:/lib/rpgc_save.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcQuests } from "game:/lib/rpgc_quests.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
function saveChecks() {
    local rows=[];local record=function(name,ok){rows.append({name=name,ok=ok});};
    local config=RpgcItems.loadProject().value;
    local state=RpgcWorldState.create({mapId="village-outskirts",x=13,y=6,moment="day"}).value;
    state.bag=RpgcItems.newBag(8,"save-test");local equipment=RpgcItems.newEquipmentSet(config,"save-test");
    local meta={partyId=RpgcProject.idsOf("party")[0],locale="zh-CN",inputSequence=12};
    RpgcItems.add(state.bag,config,"potion.heal",2);
    local captured=RpgcSave.capture(state,equipment,meta);
    record("capture-ready",captured.ok && captured.value.status=="ready");
    if(!captured.ok){print(RpgcJson.encodeCompact(captured));return rows;}
    local snapshot=captured.value.snapshot;
    local warm=RpgcSave.contentManifest();record("manifest-cache-same-content",warm.ok && RpgcJson.encodeCompact(warm.value)==RpgcJson.encodeCompact(snapshot.content));
    foreach(path,row in RpgcSave._contentCache){row.raw="stale bytes";row.checksum="00000000";break;}
    local reread=RpgcSave.contentManifest();record("manifest-cache-compares-full-raw",reread.ok && RpgcJson.encodeCompact(reread.value)==RpgcJson.encodeCompact(snapshot.content));
    RpgcSave.invalidateContentCache();local cold=RpgcSave.contentManifest();record("manifest-cache-explicit-invalidation",cold.ok && RpgcJson.encodeCompact(cold.value)==RpgcJson.encodeCompact(snapshot.content));
    record("checksum-known-ascii",RpgcSave.checksum("Wikipedia")=="11e60398");
    record("checksum-empty",RpgcSave.checksum("")=="00000001");
    record("checksum-utf8",RpgcSave.checksum("你好")=="10450489");
    local restored=RpgcSave.restore(snapshot);
    record("restore-ready",restored.ok);
    record("restore-copy",restored.ok && RpgcJson.encodeCompact(restored.value.state)==RpgcJson.encodeCompact(state));
    record("inventory-preserved",restored.ok && RpgcJson.encodeCompact(RpgcItems.snapshot(restored.value.state.bag,restored.value.equipment))==RpgcJson.encodeCompact(snapshot.payload.inventory));
    local mutate=function(source,change){local copy=RpgcWorldState.copyValue(source);change(copy);copy.rawdelete("checksum");return RpgcSave.seal(copy).value;};
    local bad=RpgcWorldState.copyValue(snapshot);bad.checksum="00000000";record("bad-checksum",!RpgcSave.restore(bad).ok);
    record("legacy-integer-zero-capacity",RpgcSave.restore(mutate(snapshot,function(s){s.payload.inventory.maxWeight=0;s.payload.inventory.maxVolume=0;})).ok);
    record("future-version",!RpgcSave.restore(mutate(snapshot,function(s){s.version=2;})).ok);
    record("unknown-field",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.extra<-true;})).ok);
    record("content-changed",!RpgcSave.restore(mutate(snapshot,function(s){s.content={};})).ok);
    record("migration-envelope-old-content",RpgcSave.verifyEnvelope(mutate(snapshot,function(s){s.content={};})).ok);
    record("unknown-map",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.mapId="missing";})).ok);
    record("outside-map",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.x=999;})).ok);
    record("fractional-coordinate",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.x=1.5;})).ok);
    record("unknown-object",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.consumed.rawset("village-outskirts/missing",true);})).ok);
    record("unknown-event",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.completedEvents.rawset("missing",true);})).ok);
    record("duplicate-slot",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.inventory.stacks.append(RpgcWorldState.copyValue(s.payload.inventory.stacks[0]));})).ok);
    record("stack-overflow",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.inventory.stacks[0].quantity=999;})).ok);
    record("counter-precision",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.inputSequence=16777216;})).ok);
    record("journal-cursor",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.questEventCursor=5;})).ok);
    record("unknown-world-field",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.extra<-1;})).ok);
    record("unknown-moment",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.world.moment="missing";})).ok);
    local damaged=RpgcWorldState.copyValue(state);damaged.bag.slots[0].quantity=1.5;record("capture-fractional-stack",!RpgcSave.capture(damaged,equipment,meta).ok);
    damaged=RpgcWorldState.copyValue(state);damaged.bag.slotCount=7;record("capture-slot-count-mismatch",!RpgcSave.capture(damaged,equipment,meta).ok);
    local wrongEquip=RpgcWorldState.copyValue(equipment);wrongEquip.slots.rawset("unknown",RpgcItems.emptyStack());record("capture-unknown-equipment",!RpgcSave.capture(state,wrongEquip,meta).ok);
    local journal=RpgcWorldState.copyValue(state);RpgcWorldState.apply(journal,{commandId="game.20",kind="set_variable",name="gold",op="add",value=1});record("input-sequence-collision",!RpgcSave.capture(journal,equipment,meta).ok);
    journal=RpgcWorldState.copyValue(state);RpgcWorldState.apply(journal,{commandId="dialogue.2.1",kind="set_variable",name="gold",op="add",value=1});record("session-sequence-collision",!RpgcSave.capture(journal,equipment,meta).ok);
    journal=RpgcWorldState.copyValue(state);journal.sessionSequence=3;RpgcWorldState.apply(journal,{commandId="event.3/steps/0",kind="set_variable",name="gold",op="add",value=1});record("event-path-sequence",RpgcSave.capture(journal,equipment,meta).ok);
    record("inventory-overweight",!RpgcSave.restore(mutate(snapshot,function(s){s.payload.inventory.capacityPolicy="slotsAndWeight";s.payload.inventory.maxWeight=0.00001;})).ok);
    local flags={eventActive=false,dialogueActive=false,battleActive=false,pendingDomainEvents=false,pendingTransfer=false};
    foreach(flag,value in flags){local context=RpgcWorldState.copyValue(flags);context.rawset(flag,true);local result=RpgcSave.capture(state,equipment,meta,context);record("deferred-"+flag,result.ok && result.value.status=="deferred");}
    record("unknown-context",!RpgcSave.capture(state,equipment,meta,{other=true}).ok);
    local active=RpgcWorldState.copyValue(state);active.activeEvents.rawset("event.1","running");record("active-events-deferred",RpgcSave.capture(active,equipment,meta).value.status=="deferred");
    local quest=RpgcProject.loadById("quest","quest.toolkit-guide").value;
    state.consumed.rawset("village-outskirts/old_chest",true);
    RpgcQuests.activate(quest,state);local claimed=RpgcQuests.claim(quest,state,config);record("quest-claim",claimed.ok);
    local journaled=RpgcQuests.consume([quest],state,claimed.value.domainEvents);record("quest-events-journaled",journaled.ok);
    local saved=RpgcSave.capture(state,equipment,meta);record("claimed-capture",saved.ok);
    if(saved.ok){local loaded=RpgcSave.restore(saved.value.snapshot);local before=RpgcJson.encodeCompact(loaded.value.state);local repeated=RpgcQuests.claim(quest,loaded.value.state,config);record("claimed-no-reward-after-load",repeated.ok && repeated.value.duplicate && before==RpgcJson.encodeCompact(loaded.value.state));}
    return rows;
}
function runSaveChecks(){local checks=saveChecks();local ok=true;foreach(row in checks)if(!row.ok)ok=false;print("RPGC_SAVE="+RpgcJson.encodeCompact({ok=ok,checks=checks})+"\n");}
runSaveChecks();
