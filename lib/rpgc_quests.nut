// Quest progress consumes shared domain events; rewards use shared commands.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcSystems } from "game:/lib/rpgc_systems.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"

export class RpgcQuests {}
RpgcQuests.version <- 1
RpgcQuests.kinds <- ["quest"]
RpgcQuests.failResult <- function(code,message,path="$") {
    return Rpgc.fail([Rpgc.error("quest."+code,message,path,"")]);
}
RpgcQuests.semanticDiagnostics <- function(doc) {
    local diagnostics=[]; local seen={};
    if (!Rpgc.validId(doc.id)) diagnostics.append(Rpgc.error("quest.id","invalid quest id","/id",""));
    foreach (dependency in Rpgc.get(doc,"dependencies",[])) {
        if (!Rpgc.validId(dependency) || dependency==doc.id || seen.rawin(dependency))
            diagnostics.append(Rpgc.error("quest.dependency","dependency must be a unique different quest id","/dependencies",""));
        seen.rawset(dependency,true);
    }
    if (doc.rawin("condition")) diagnostics=RpgcSystems.conditionDiagnostics(doc.condition,"/condition",RpgcSystems.momentTable(),diagnostics);
    seen={};
    for (local i=0;i<doc.objectives.len();i+=1) {
        local objective=doc.objectives[i]; local at="/objectives/"+i;
        if (!Rpgc.validId(objective.id) || seen.rawin(objective.id)) diagnostics.append(Rpgc.error("quest.objective-id","invalid or duplicate objective id",at+"/id",""));
        seen.rawset(objective.id,true);
        if (objective.rawin("condition")) diagnostics=RpgcSystems.conditionDiagnostics(objective.condition,at+"/condition",RpgcSystems.momentTable(),diagnostics);
        if (objective.rawin("initialCondition")) diagnostics=RpgcSystems.conditionDiagnostics(objective.initialCondition,at+"/initialCondition",RpgcSystems.momentTable(),diagnostics);
        local matcher=Rpgc.get(objective,"match",{});
        foreach (key,value in matcher) if (typeof value=="string" && value=="") diagnostics.append(Rpgc.error("quest.match","match strings must be nonempty",at+"/match/"+key,""));
        if (matcher.rawin("value") && !RpgcWorldState.safeNumber(matcher.value)) diagnostics.append(Rpgc.error("quest.precision","match value is outside exact range",at+"/match/value",""));
    }
    for (local i=0;i<doc.rewards.len();i+=1) {
        local reward=doc.rewards[i]; local at="/rewards/"+i; local allowed=[]; local required=[];
        if (reward.kind=="set_variable") {allowed=["kind","name","op","value"];required=["name","op","value"];}
        if (reward.kind=="consume_object") {allowed=["kind","mapId","objectName"];required=["mapId","objectName"];}
        if (reward.kind=="give_item") {allowed=["kind","itemId","quantity"];required=["itemId","quantity"];}
        foreach (key,value in reward) if (allowed.find(key)==null) diagnostics.append(Rpgc.error("quest.reward-field","field does not belong to reward kind",at+"/"+key,""));
        foreach (key in required) if (!reward.rawin(key) || (typeof reward.rawget(key)=="string" && reward.rawget(key)=="")) diagnostics.append(Rpgc.error("quest.reward-required","reward requires "+key,at,""));
        if (reward.rawin("value") && !RpgcWorldState.safeNumber(reward.value)) diagnostics.append(Rpgc.error("quest.precision","reward value is outside exact range",at+"/value",""));
    }
    return diagnostics;
}
RpgcQuests.conditionRefs <- function(condition,at,out) {
    if (Rpgc.get(condition,"kind","")=="object_consumed") out.append({kind="map",id=condition.mapId,path=at+"/mapId"});
}
RpgcQuests.references <- function(doc) {
    local out=[]; local dependencies=Rpgc.get(doc,"dependencies",[]);
    for(local i=0;i<dependencies.len();i+=1) out.append({kind="quest",id=dependencies[i],path="/dependencies/"+i});
    this.conditionRefs(Rpgc.get(doc,"condition",{}),"/condition",out);
    for(local i=0;i<doc.objectives.len();i+=1) {
        local objective=doc.objectives[i]; local at="/objectives/"+i; local matcher=Rpgc.get(objective,"match",{});
        foreach (field,kind in {mapId="map",itemId="item",questId="quest"}) if (matcher.rawin(field)) out.append({kind=kind,id=matcher.rawget(field),path=at+"/match/"+field});
        this.conditionRefs(Rpgc.get(objective,"condition",{}),at+"/condition",out);
        this.conditionRefs(Rpgc.get(objective,"initialCondition",{}),at+"/initialCondition",out);
    }
    for(local i=0;i<doc.rewards.len();i+=1) {
        local reward=doc.rewards[i]; local at="/rewards/"+i;
        if(reward.kind=="give_item") out.append({kind="item",id=reward.itemId,path=at+"/itemId"});
        if(reward.kind=="consume_object") out.append({kind="map",id=reward.mapId,path=at+"/mapId"});
    }
    return out;
}
RpgcQuests.checkDefinition <- function(doc) {
    foreach(name in ["condition","quest"]) {
        local read=RpgcStore.readText("schema/eve.rpgc."+name+".json"); if(!read.ok)return read;
        if(!eve.Schema().registerJson(read.value).ok)return this.failResult("schema-register","cannot register "+name);
    }
    if(!eve.Schema().validateJson("eve.rpgc.quest",RpgcJson.encodeCompact(doc)).ok)return this.failResult("schema","quest violates strict schema");
    return Rpgc.result(doc,this.semanticDiagnostics(doc));
}
RpgcQuests.progress <- function(doc,state) {
    if(typeof state!="table" || !state.rawin("quests") || typeof state.quests!="table")return this.failResult("state","shared world state with quests is required");
    if(!state.quests.rawin(doc.id))return Rpgc.ok(0);
    local row=state.quests.rawget(doc.id);
    if(row.definitionFingerprint!=RpgcJson.fingerprint(doc))return this.failResult("definition-changed","quest definition changed; explicit migration is required");
    if(row.counts.len()!=doc.objectives.len())return this.failResult("progress","objective set differs from definition");
    foreach(objective in doc.objectives) if(!row.counts.rawin(objective.id) || !RpgcWorldState.safeCounter(row.counts.rawget(objective.id)) || row.counts.rawget(objective.id)>objective.count)return this.failResult("progress","invalid objective progress");
    return Rpgc.ok(row);
}
RpgcQuests.status <- function(doc,state) {
    local checked=this.checkDefinition(doc);if(!checked.ok)return checked;
    local progress=this.progress(doc,state);if(!progress.ok)return progress;
    if(progress.value==0)return Rpgc.ok({id=doc.id,status="inactive",counts={}});
    local out=RpgcWorldState.copyValue(progress.value);out.id<-doc.id;return Rpgc.ok(out);
}
RpgcQuests.emit <- function(candidate,questId,kind,events) {
    if(!RpgcWorldState.safeCounter(candidate.revision+1))return this.failResult("precision","world revision exhausted");
    candidate.revision+=1;
    events.append({sequence=candidate.revision,commandId=questId+"."+kind,kind=kind,payload={questId=questId}});
    return Rpgc.ok(true);
}
RpgcQuests.commit <- function(state,candidate,events,duplicate=false) {
    foreach(key,value in candidate)state.rawset(key,value);
    return Rpgc.ok({state=state,domainEvents=events,duplicate=duplicate});
}
RpgcQuests.activate <- function(doc,state) {
    local checked=this.checkDefinition(doc);if(!checked.ok)return checked;
    local progress=this.progress(doc,state);if(!progress.ok)return progress;
    if(progress.value!=0) {
        if(progress.value.status=="failed")return this.failResult("failed","failed quests cannot be restarted implicitly");
        return Rpgc.ok({state=state,domainEvents=[],duplicate=true});
    }
    foreach(dependency in Rpgc.get(doc,"dependencies",[])) if(!state.quests.rawin(dependency) || state.quests.rawget(dependency).status!="claimed")return this.failResult("dependency","dependency must be claimed: "+dependency);
    if(doc.rawin("condition")) {
        local condition=RpgcWorldState.condition(state,doc.condition);if(!condition.ok)return condition;
        if(!condition.value)return this.failResult("condition","activation condition is false");
    }
    local candidate=RpgcWorldState.copyValue(state); local counts={};local events=[];
    local alreadyComplete=true;
    foreach(objective in doc.objectives) {
        local count=0;
        if(objective.rawin("initialCondition")) {
            local initial=RpgcWorldState.condition(state,objective.initialCondition);if(!initial.ok)return initial;
            if(initial.value)count=objective.count;
        }
        counts.rawset(objective.id,count);if(count<objective.count)alreadyComplete=false;
    }
    candidate.quests.rawset(doc.id,{status="active",counts=counts,lastSequence=state.revision,definitionFingerprint=RpgcJson.fingerprint(doc)});
    local emitted=this.emit(candidate,doc.id,"quest_activated",events);if(!emitted.ok)return emitted;
    if(alreadyComplete) {
        candidate.quests.rawget(doc.id).status="completed";
        local completed=this.emit(candidate,doc.id,"quest_completed",events);if(!completed.ok)return completed;
    }
    return this.commit(state,candidate,events);
}
RpgcQuests.matches <- function(objective,event) {
    if(objective.eventKind!=event.kind)return false;
    foreach(key,value in Rpgc.get(objective,"match",{})) {
        if(!event.payload.rawin(key))return false;
        local actual=event.payload.rawget(key);
        if(Rpgc.isNumber(actual) && Rpgc.isNumber(value)) {if(actual!=value)return false;}
        else if(!RpgcJson.equal(actual,value))return false;
    }
    return true;
}
RpgcQuests.consume <- function(definitions,state,domainEvents) {
    if(typeof definitions!="array" || definitions.len()>128 || typeof domainEvents!="array" || domainEvents.len()>256)return this.failResult("budget","consume accepts at most 128 definitions and 256 events");
    local byId={};local ordered=[];
    foreach(doc in definitions) {
        local checked=this.checkDefinition(doc);if(!checked.ok)return checked;
        if(byId.rawin(doc.id))return this.failResult("duplicate-definition","quest id appears twice");
        byId.rawset(doc.id,doc);ordered.append(doc.id);
        local progress=this.progress(doc,state);if(!progress.ok)return progress;
    }
    ordered.sort();
    foreach(id,row in state.quests)if(row.status=="active" && !byId.rawin(id))return this.failResult("missing-definition","active quest definition missing: "+id);
    local input=RpgcWorldState.copyValue(domainEvents);
    foreach(event in input) {
        if(typeof event!="table" || !RpgcWorldState.safeCounter(Rpgc.get(event,"sequence",0)) || event.sequence<=0 || event.sequence>state.revision
            || typeof Rpgc.get(event,"commandId",0)!="string" || event.commandId=="" || typeof Rpgc.get(event,"kind",0)!="string" || event.kind=="" || typeof Rpgc.get(event,"payload",0)!="table")return this.failResult("event","invalid domain event envelope/sequence");
    }
    input.sort(function(a,b){return a.sequence<b.sequence?-1:(a.sequence>b.sequence?1:0);});
    local candidate=RpgcWorldState.copyValue(state);local changed=false;local events=[];
    foreach(event in input) {
        local key=""+event.sequence;local signature=RpgcJson.encodeCompact(event);
        if(candidate.questEventIds.rawin(key)) {
            if(candidate.questEventIds.rawget(key)!=signature)return this.failResult("event-conflict","sequence was reused for another event");
            continue;
        }
        if(event.sequence<=candidate.questEventCursor)return this.failResult("event-order","unseen event arrived behind the committed cursor");
        if(candidate.questEventIds.len()>=16384)return this.failResult("journal-budget","quest event journal requires explicit compaction");
        candidate.questEventIds.rawset(key,signature);candidate.questEventCursor=event.sequence;changed=true;
        foreach(id in ordered) {
            if(!candidate.quests.rawin(id))continue;
            local row=candidate.quests.rawget(id);local doc=byId.rawget(id);
            if(row.status!="active" || event.sequence<=row.lastSequence)continue;
            foreach(objective in doc.objectives) {
                if(!this.matches(objective,event))continue;
                if(objective.rawin("condition")) {
                    local condition=RpgcWorldState.condition(candidate,objective.condition);if(!condition.ok)return condition;
                    if(!condition.value)continue;
                }
                local count=row.counts.rawget(objective.id);
                if(count<objective.count)row.counts.rawset(objective.id,count+1);
            }
            row.lastSequence=event.sequence;
        }
    }
    foreach(id in ordered) {
        if(!candidate.quests.rawin(id))continue;
        local row=candidate.quests.rawget(id);if(row.status!="active")continue;
        local complete=true;foreach(objective in byId.rawget(id).objectives)if(row.counts.rawget(objective.id)<objective.count)complete=false;
        if(complete) {
            row.status="completed";
            local emitted=this.emit(candidate,id,"quest_completed",events);if(!emitted.ok)return emitted;
        }
    }
    if(changed && events.len()==0) {
        if(!RpgcWorldState.safeCounter(candidate.revision+1))return this.failResult("precision","world revision exhausted");
        candidate.revision+=1;
    }
    return this.commit(state,candidate,events,!changed);
}
RpgcQuests.claim <- function(doc,state,itemConfig=0) {
    local checked=this.checkDefinition(doc);if(!checked.ok)return checked;
    local progress=this.progress(doc,state);if(!progress.ok)return progress;
    if(progress.value==0)return this.failResult("inactive","quest has not been activated");
    if(progress.value.status=="claimed")return Rpgc.ok({state=state,domainEvents=[],duplicate=true});
    if(progress.value.status!="completed")return this.failResult("not-completed","quest must complete before claiming");
    local candidate=RpgcWorldState.copyValue(state);local commands=[];
    for(local i=0;i<doc.rewards.len();i+=1) {
        local command=RpgcWorldState.copyValue(doc.rewards[i]);command.commandId<-doc.id+".reward."+i;commands.append(command);
    }
    local rewards=RpgcWorldState.applyBatch(candidate,commands,itemConfig);if(!rewards.ok)return rewards;
    local events=rewards.value.domainEvents;
    candidate.quests.rawget(doc.id).status="claimed";
    local emitted=this.emit(candidate,doc.id,"quest_claimed",events);if(!emitted.ok)return emitted;
    return this.commit(state,candidate,events);
}
RpgcQuests.fail <- function(doc,state) {
    local checked=this.checkDefinition(doc);if(!checked.ok)return checked;
    local progress=this.progress(doc,state);if(!progress.ok)return progress;
    if(progress.value==0)return this.failResult("inactive","quest has not been activated");
    if(progress.value.status=="failed")return Rpgc.ok({state=state,domainEvents=[],duplicate=true});
    if(progress.value.status!="active")return this.failResult("not-active","only active quests may fail");
    local candidate=RpgcWorldState.copyValue(state);local events=[];candidate.quests.rawget(doc.id).status="failed";
    local emitted=this.emit(candidate,doc.id,"quest_failed",events);if(!emitted.ok)return emitted;
    return this.commit(state,candidate,events);
}

// Project-level dependency gate. Iterative elimination avoids recursion limits.
RpgcQuests.dependencyDiagnostics <- function(definitions) {
    local diagnostics=[];local byId={};local ids=[];
    if(typeof definitions!="array" || definitions.len()>256)return [Rpgc.error("quest.dependency-budget","dependency graph exceeds 256 quest definitions","$","")];
    foreach(doc in definitions) {
        if(typeof doc!="table" || !Rpgc.validId(Rpgc.get(doc,"id","")) || typeof Rpgc.get(doc,"dependencies",[])!="array") {
            diagnostics.append(Rpgc.error("quest.dependency-shape","invalid quest dependency descriptor","$",""));continue;
        }
        if(byId.rawin(doc.id))diagnostics.append(Rpgc.error("quest.duplicate-definition","duplicate quest id",doc.id,""));
        else {byId.rawset(doc.id,doc);ids.append(doc.id);}
    }
    ids.sort();local pending={};foreach(id in ids)pending.rawset(id,true);
    foreach(id in ids)foreach(dependency in Rpgc.get(byId.rawget(id),"dependencies",[]))if(typeof dependency!="string" || !byId.rawin(dependency))
        diagnostics.append(Rpgc.error("quest.missing-dependency","missing dependency of "+id,RpgcProject.pathOf("quest",id)+":/dependencies",""));
    local changed=true;
    while(changed) {
        changed=false;
        foreach(id in ids) {
            if(!pending.rawin(id))continue;
            local blocked=false;
            foreach(dependency in Rpgc.get(byId.rawget(id),"dependencies",[]))if(typeof dependency=="string" && pending.rawin(dependency))blocked=true;
            if(!blocked){pending.rawdelete(id);changed=true;}
        }
    }
    foreach(id in ids)if(pending.rawin(id))diagnostics.append(Rpgc.error("quest.dependency-cycle","quest depends on a cyclic dependency graph",RpgcProject.pathOf("quest",id)+":/dependencies","break the dependency cycle"));
    return diagnostics;
}
RpgcQuests.extraDiagnostics <- function() {
    local loaded=RpgcProject.loadKind("quest");if(!loaded.ok)return loaded.diagnostics;
    return this.dependencyDiagnostics(loaded.value);
}
