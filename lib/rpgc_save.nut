// Versioned safe-point snapshots. Adler-32 detects corruption; it is not authentication.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"
import { RpgcQuests } from "game:/lib/rpgc_quests.nut"
export class RpgcSave {}
RpgcSave.fail <- function(message) { return Rpgc.fail([Rpgc.error("save.invalid",message,"$","")]); }
RpgcSave.keys <- function(value, names) {
    if(typeof value!="table" || value.len()!=names.len())return false;
    foreach(name in names)if(!value.rawin(name))return false;
    return true;
}
RpgcSave.checksum <- function(text) {
    local a=1; local b=0;
    for(local i=0;i<text.len();i+=1){a=(a+(text[i]&255))%65521;b=(b+a)%65521;}
    local digits="0123456789abcdef";local out="";
    foreach(part in [b,a])for(local shift=12;shift>=0;shift-=4)out+=digits.slice((part>>shift)&15,((part>>shift)&15)+1);
    return out;
}
RpgcSave.seal <- function(body) {
    if(!this.keys(body,["format","version","gameId","content","payload"]))return this.fail("snapshot body fields differ from contract");
    local out=RpgcWorldState.copyValue(body);
    out.checksum<-this.checksum(RpgcJson.encodeCompact(body));return Rpgc.ok(out);
}
RpgcSave._contentCache <- {}
RpgcSave.invalidateContentCache <- function() {this._contentCache<-{};}
RpgcSave.contentManifest <- function() {
    local loaded=RpgcProject.load("");if(!loaded.ok)return loaded;
    local out={};local nextCache={};
    foreach(kind in RpgcProject.kinds())foreach(id in RpgcProject.idsOf(kind)) {
        local path=RpgcProject.pathOf(kind,id);local raw="";
        try {raw=eve.Filesystem().readText(path);}catch(error){return this.fail("content read failed: "+path);}
        if(raw=="")return this.fail("content is missing or empty: "+path);
        // Read on every call. Full byte equality, not timestamps or a short hash,
        // admits reuse; additions/removals are rediscovered by Project.load above.
        local cached=this._contentCache.rawin(path)?this._contentCache.rawget(path):null;
        if(cached==null || cached.raw!=raw) {
            local doc=RpgcJson.parse(raw);if(!doc.ok)return doc;
            cached={raw=raw,checksum=this.checksum(RpgcJson.encodeCompact(doc.value))};
        }
        nextCache.rawset(path,cached);out.rawset(kind+"/"+id,cached.checksum);
    }
    this._contentCache<-nextCache;
    return Rpgc.ok(out);
}
RpgcSave._inventory <- function(doc,config) {
    if(!this.keys(doc,["format","version","id","slotCount","maxWeight","maxVolume","capacityPolicy","stacks","equipped"]))return this.fail("inventory fields differ from contract");
    if(doc.format!="eve.rpgc.items.snapshot" || typeof doc.version!="integer" || doc.version!=1 || typeof doc.id!="string" || doc.id=="" || !RpgcWorldState.safeCounter(doc.slotCount) || doc.slotCount<1 || doc.slotCount>4096)return this.fail("invalid inventory header");
    foreach(field in ["maxWeight","maxVolume"])if(!RpgcWorldState.safeNumber(doc.rawget(field)) || doc.rawget(field)<0)return this.fail("invalid inventory capacity");
    if(["slotsAndWeight","slots","weight","unlimited"].find(doc.capacityPolicy)==null || typeof doc.stacks!="array" || typeof doc.equipped!="array")return this.fail("invalid inventory collections/policy");
    local occupied={};
    foreach(row in doc.stacks) {
        if(!this.keys(row,["bagSlot","itemId","quantity"]) || !RpgcWorldState.safeCounter(row.bagSlot) || row.bagSlot>=doc.slotCount || !RpgcWorldState.safeCounter(row.quantity) || row.quantity<1 || typeof row.itemId!="string")return this.fail("invalid inventory row");
        local key=""+row.bagSlot;if(occupied.rawin(key))return this.fail("duplicate inventory slot");occupied.rawset(key,true);
        local def=RpgcItems.definitionOf(config,row.itemId);if(def==0 || row.quantity>def.maxStack)return this.fail("unknown item or stack overflow");
    }
    local worn={};foreach(row in doc.equipped) {
        if(!this.keys(row,["slot","itemId"]) || typeof row.slot!="string" || typeof row.itemId!="string" || worn.rawin(row.slot))return this.fail("invalid or duplicate equipment slot");
        worn.rawset(row.slot,true);
    }
    local restored=RpgcItems.restore(RpgcJson.encodeCompact(doc),config);if(!restored.ok)return restored;
    if((doc.capacityPolicy=="slotsAndWeight" || doc.capacityPolicy=="weight") && doc.maxWeight>0 && RpgcItems.usedWeight(restored.value.bag,config)>doc.maxWeight+0.000001)return this.fail("inventory exceeds weight capacity");
    if(doc.capacityPolicy=="slotsAndWeight" && doc.maxVolume>0 && RpgcItems.usedVolume(restored.value.bag,config)>doc.maxVolume+0.000001)return this.fail("inventory exceeds volume capacity");
    // Items stores capacity numbers as floats. Admit exact legacy integer values
    // only for these two fields; quantities/slots and all other fields stay strict.
    local expected=RpgcWorldState.copyValue(doc);
    foreach(field in ["maxWeight","maxVolume"]) {
        local actual=restored.value.bag.rawget(field);
        if(actual!=doc.rawget(field))return this.fail("inventory capacity loses numeric precision");
        expected.rawset(field,actual);
    }
    if(RpgcJson.encodeCompact(RpgcItems.snapshot(restored.value.bag,restored.value.equipment))!=RpgcJson.encodeCompact(expected))return this.fail("inventory cannot roundtrip without loss");
    return restored;
}
RpgcSave.verifyEnvelope <- function(snapshot) {
    if(!this.keys(snapshot,["format","version","gameId","content","payload","checksum"]))return this.fail("snapshot fields differ from contract");
    if(snapshot.format!="eve.rpgc.world.snapshot" || typeof snapshot.version!="integer" || snapshot.version!=1 || snapshot.gameId!="rpg-classic")return this.fail("unsupported snapshot format/version/game");
    local body=RpgcWorldState.copyValue(snapshot);body.rawdelete("checksum");
    if(typeof snapshot.checksum!="string" || snapshot.checksum!=this.checksum(RpgcJson.encodeCompact(body)))return this.fail("checksum mismatch (adler32-utf8)");
    if(typeof snapshot.content!="table" || !this.keys(snapshot.payload,["world","inventory","partyId","locale","inputSequence"]))return this.fail("invalid content/payload shape");
    local p=snapshot.payload;
    if(typeof p.world!="table" || typeof p.inventory!="table" || typeof p.partyId!="string" || p.partyId=="" || typeof p.locale!="string" || p.locale=="" || !RpgcWorldState.safeCounter(p.inputSequence))return this.fail("invalid payload shape/types");
    foreach(key,value in snapshot.content) {
        if(typeof key!="string" || key.find("/")==null || typeof value!="string" || value.len()!=8)return this.fail("invalid content manifest entry");
        foreach(c in value)if(!((c>=48 && c<=57) || (c>=97 && c<=102)))return this.fail("invalid content checksum");
    }
    return Rpgc.ok(body);
}
RpgcSave.restore <- function(snapshot) {
    local envelope=this.verifyEnvelope(snapshot);if(!envelope.ok)return envelope;
    local manifest=this.contentManifest();if(!manifest.ok)return manifest;
    if(RpgcJson.encodeCompact(snapshot.content)!=RpgcJson.encodeCompact(manifest.value))return this.fail("content changed; explicit migration required");
    local p=snapshot.payload;
    if(!this.keys(p,["world","inventory","partyId","locale","inputSequence"]) || typeof p.partyId!="string" || typeof p.locale!="string" || p.locale=="" || !RpgcWorldState.safeCounter(p.inputSequence))return this.fail("invalid payload/meta");
    if(!RpgcProject.loadById("party",p.partyId).ok)return this.fail("unknown party");
    local defaults=RpgcWorldState.create().value;local names=[];foreach(key,value in defaults)names.append(key);
    if(!this.keys(p.world,names) || p.world.bag!=0)return this.fail("world fields differ from contract");
    local made=RpgcWorldState.create(p.world);if(!made.ok)return made;local state=made.value;
    if(state.activeEvents.len()!=0)return this.fail("active sessions cannot be restored");
    if(state.questEventCursor>state.revision || state.commandIds.len()>state.revision || state.questEventIds.len()>16384)return this.fail("invalid journal bounds");
    foreach(id,signature in state.commandIds) {
        local parsed=RpgcJson.parse(signature);
        if(!parsed.ok || typeof parsed.value!="table" || Rpgc.get(parsed.value,"commandId","")!=id || RpgcJson.encodeCompact(parsed.value)!=signature)return this.fail("invalid command journal");
    }
    local highestEvent=0;
    foreach(id,signature in state.questEventIds) {
        local parsed=RpgcJson.parse(signature);if(!parsed.ok || typeof parsed.value!="table")return this.fail("invalid event journal");
        if(!this.keys(parsed.value,["sequence","commandId","kind","payload"]) || typeof parsed.value.commandId!="string" || parsed.value.commandId=="" || typeof parsed.value.kind!="string" || parsed.value.kind=="" || typeof parsed.value.payload!="table")return this.fail("invalid event journal envelope");
        local seq=Rpgc.get(parsed.value,"sequence",-1);
        if(!RpgcWorldState.safeCounter(seq) || seq<1 || seq>state.questEventCursor || id!=""+seq || RpgcJson.encodeCompact(parsed.value)!=signature)return this.fail("invalid event journal cursor");
        if(seq>highestEvent)highestEvent=seq;
    }
    if(highestEvent!=state.questEventCursor)return this.fail("event cursor lacks matching journal entry");
    foreach(id,signature in state.commandIds) {
        local input=this._identitySequence(id,"game.");if(input<0 || input>p.inputSequence)return this.fail("input sequence would reuse command IDs");
        foreach(prefix in ["event.","dialogue."]) {local seq=this._identitySequence(id,prefix);if(seq<0 || seq>state.sessionSequence)return this.fail("session sequence would reuse command IDs");}
    }
    local moments={};foreach(id in RpgcProject.idsOf("world")) {local doc=RpgcProject.loadById("world",id);if(!doc.ok)return doc;foreach(name,band in Rpgc.get(doc.value,"clock.moments",{}))moments.rawset(name,true);}
    if(!moments.rawin(state.moment))return this.fail("unknown world moment");
    local mapDoc=RpgcProject.loadById("map",state.mapId);if(!mapDoc.ok)return this.fail("unknown map");
    if(!RpgcWorldState.safeCounter(state.x) || !RpgcWorldState.safeCounter(state.y) || state.x>=mapDoc.value.width || state.y>=mapDoc.value.height)return this.fail("map coordinates outside map");
    local objects={};foreach(id in RpgcProject.idsOf("map")) {
        local doc=RpgcProject.loadById("map",id);if(!doc.ok)return doc;
        foreach(layer in doc.value.layers)foreach(obj in Rpgc.get(layer,"objects",[]))objects.rawset(id+"/"+Rpgc.get(obj,"name",""),true);
    }
    foreach(key,value in state.consumed)if(!objects.rawin(key))return this.fail("unknown consumed object");
    foreach(id,value in state.completedEvents)if(!RpgcProject.loadById("event",id).ok)return this.fail("unknown completed event");
    foreach(id,row in state.quests) {
        if(!this.keys(row,["status","counts","lastSequence","definitionFingerprint"]) || row.lastSequence>state.revision)return this.fail("invalid quest record");
        local doc=RpgcProject.loadById("quest",id);if(!doc.ok)return this.fail("unknown quest");
        local progress=RpgcQuests.status(doc.value,state);if(!progress.ok)return progress;
        local complete=true;foreach(obj in doc.value.objectives)if(row.counts.rawget(obj.id)<obj.count)complete=false;
        if((row.status=="completed" || row.status=="claimed") && !complete)return this.fail("completed quest has incomplete objectives");
        if(row.status=="active" && complete)return this.fail("active quest is already complete");
    }
    local config=RpgcItems.loadProject();if(!config.ok)return config;
    local inventory=this._inventory(p.inventory,config.value);if(!inventory.ok)return inventory;
    state.bag=inventory.value.bag;
    return Rpgc.ok({state=state,equipment=inventory.value.equipment,partyId=p.partyId,locale=p.locale,inputSequence=p.inputSequence});
}
RpgcSave._captureInventory <- function(bag,equipment) {
    if(!this.keys(bag,["id","slotCount","maxWeight","maxVolume","capacityPolicy","stackRule","slots"]) || typeof bag.slots!="array" || !RpgcWorldState.safeCounter(bag.slotCount) || bag.slotCount!=bag.slots.len() || bag.stackRule!=RpgcItems.defaultStackRule)return this.fail("bag shape/stack rule cannot be preserved");
    if(!this.keys(equipment,["id","order","slots"]) || typeof equipment.id!="string" || equipment.id!=bag.id || typeof equipment.order!="array" || typeof equipment.slots!="table")return this.fail("invalid equipment shape");
    local config=RpgcItems.loadProject();if(!config.ok)return config;
    local canonical=RpgcItems.newEquipmentSet(config.value,equipment.id);
    if(RpgcJson.encodeCompact(equipment.order)!=RpgcJson.encodeCompact(canonical.order) || equipment.slots.len()!=canonical.slots.len())return this.fail("equipment slot catalogue differs");
    foreach(stack in bag.slots) {
        if(!this.keys(stack,["itemId","quantity"]) || typeof stack.itemId!="string" || !RpgcWorldState.safeCounter(stack.quantity) || (stack.itemId=="")!=(stack.quantity==0))return this.fail("invalid bag stack");
    }
    foreach(slot,stack in equipment.slots) {
        if(!canonical.slots.rawin(slot) || !this.keys(stack,["itemId","quantity"]) || typeof stack.itemId!="string" || !RpgcWorldState.safeCounter(stack.quantity) || (stack.itemId==""?stack.quantity!=0:stack.quantity!=1))return this.fail("invalid equipment stack");
    }
    return this._inventory(RpgcItems.snapshot(bag,equipment),config.value);
}
RpgcSave._identitySequence <- function(id,prefix) {
    if(id.len()<=prefix.len() || id.slice(0,prefix.len())!=prefix)return 0;
    local tail=id.slice(prefix.len());local end=tail.find(".");local slash=tail.find("/");if(slash!=null && (end==null || slash<end))end=slash;if(end!=null)tail=tail.slice(0,end);
    if(tail=="")return -1;
    foreach(c in tail)if(c<48 || c>57)return -1;
    local value=tail.tofloat();if(!RpgcWorldState.safeCounter(value) || value<1 || tail!=""+value.tointeger())return -1;
    return value;
}
RpgcSave.capture <- function(state,equipment,meta,context=0) {
    local flags=["eventActive","dialogueActive","battleActive","pendingDomainEvents","pendingTransfer"];
    if(context!=0) {
        if(!this.keys(context,flags))return this.fail("safe-point context requires all five flags");
        foreach(flag in flags)if(typeof context.rawget(flag)!="bool")return this.fail("safe-point flags must be boolean");
        foreach(flag in flags)if(context.rawget(flag))return Rpgc.ok({status="deferred",reason=flag});
    }
    if(typeof state!="table" || typeof Rpgc.get(state,"activeEvents",0)!="table")return this.fail("invalid state");
    if(state.activeEvents.len()>0)return Rpgc.ok({status="deferred",reason="activeEvents"});
    if(!this.keys(meta,["partyId","locale","inputSequence"]))return this.fail("invalid capture metadata");
    local validated=RpgcWorldState.create(state);if(!validated.ok)return validated;
    if(typeof state.bag!="table" || typeof equipment!="table" || typeof Rpgc.get(equipment,"order",0)!="array")return this.fail("inventory/equipment required");
    local inventoryCheck=this._captureInventory(state.bag,equipment);if(!inventoryCheck.ok)return inventoryCheck;
    local manifest=this.contentManifest();if(!manifest.ok)return manifest;
    local world=RpgcWorldState.copyValue(state);world.bag=0;
    local sealed=this.seal({format="eve.rpgc.world.snapshot",version=1,gameId="rpg-classic",content=manifest.value,
        payload={world=world,inventory=RpgcItems.snapshot(state.bag,equipment),partyId=meta.partyId,locale=meta.locale,inputSequence=meta.inputSequence}});
    if(!sealed.ok)return sealed;local restored=this.restore(sealed.value);if(!restored.ok)return restored;
    return Rpgc.ok({status="ready",snapshot=sealed.value});
}
