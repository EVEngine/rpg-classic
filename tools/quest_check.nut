import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcQuests } from "game:/lib/rpgc_quests.nut"

function questChecks() {
    local checks=[];local record=function(name,ok){checks.append({name=name,ok=ok});};
    local doc=RpgcJson.parse(RpgcStore.readText("content/quests/quest.toolkit-guide.json").value).value;
    local config=RpgcItems.loadProject().value;
    local state=RpgcWorldState.create({bag=RpgcItems.newBag(2,"quest-test")}).value;
    record("definition",RpgcQuests.checkDefinition(doc).ok);
    record("inactive",RpgcQuests.status(doc,state).value.status=="inactive");
    record("inactive-cannot-claim",!RpgcQuests.claim(doc,state,config).ok);
    local activated=RpgcQuests.activate(doc,state);
    record("activate",activated.ok && state.quests.rawget(doc.id).status=="active" && activated.value.domainEvents[0].kind=="quest_activated");
    local before=RpgcJson.encodeCompact(state);
    record("activate-idempotent",RpgcQuests.activate(doc,state).value.duplicate && before==RpgcJson.encodeCompact(state));
    record("active-cannot-claim",!RpgcQuests.claim(doc,state,config).ok);
    local opened=RpgcWorldState.apply(state,{commandId="open.chest",kind="consume_object",mapId="village-outskirts",objectName="old_chest"});
    local consumed=RpgcQuests.consume([doc],state,opened.value.domainEvents);
    record("objective-completes",consumed.ok && state.quests.rawget(doc.id).status=="completed" && state.quests.rawget(doc.id).counts.rawget("open-chest")==1);
    record("completion-event",consumed.value.domainEvents.len()==1 && consumed.value.domainEvents[0].kind=="quest_completed");
    record("complete-is-not-claim",state.gold==0 && RpgcItems.countOf(state.bag,"potion.heal")==0);
    before=RpgcJson.encodeCompact(state);
    record("event-idempotent",RpgcQuests.consume([doc],state,opened.value.domainEvents).value.duplicate && before==RpgcJson.encodeCompact(state));
    local claim=RpgcQuests.claim(doc,state,config);
    record("claim",claim.ok && state.quests.rawget(doc.id).status=="claimed" && state.gold==5 && RpgcItems.countOf(state.bag,"potion.heal")==1);
    before=RpgcJson.encodeCompact(state);
    record("claim-idempotent",RpgcQuests.claim(doc,state,config).value.duplicate && before==RpgcJson.encodeCompact(state));
    record("claimed-cannot-fail",!RpgcQuests.fail(doc,state).ok);
    record("world-state-roundtrip",RpgcWorldState.create(state).ok);
    record("reference-map-and-item",RpgcQuests.references(doc).len()==3);

    local full=RpgcWorldState.create({bag=RpgcItems.newBag(1,"full")}).value;
    RpgcItems.add(full.bag,config,"potion.heal",20);
    RpgcQuests.activate(doc,full);
    local fullEvent=RpgcWorldState.apply(full,{commandId="full.chest",kind="consume_object",mapId="village-outskirts",objectName="old_chest"});
    RpgcQuests.consume([doc],full,fullEvent.value.domainEvents);
    before=RpgcJson.encodeCompact(full);
    record("full-bag-atomic",!RpgcQuests.claim(doc,full,config).ok && before==RpgcJson.encodeCompact(full) && full.quests.rawget(doc.id).status=="completed");
    local invalidConfig=RpgcWorldState.copyValue(config);invalidConfig.items.rawget("potion.heal").maxStack=1.5;
    record("invalid-item-config-atomic",!RpgcQuests.claim(doc,full,invalidConfig).ok && before==RpgcJson.encodeCompact(full));
    record("missing-item-config-atomic",!RpgcQuests.claim(doc,full).ok && before==RpgcJson.encodeCompact(full));
    RpgcItems.remove(full.bag,"potion.heal",1);
    record("retry-after-space",RpgcQuests.claim(doc,full,config).ok && full.gold==5 && RpgcItems.countOf(full.bag,"potion.heal")==20);

    local failed=RpgcWorldState.create().value;RpgcQuests.activate(doc,failed);
    record("fail-transition",RpgcQuests.fail(doc,failed).ok && failed.quests.rawget(doc.id).status=="failed");
    before=RpgcJson.encodeCompact(failed);
    record("fail-idempotent",RpgcQuests.fail(doc,failed).value.duplicate && before==RpgcJson.encodeCompact(failed));
    record("failed-no-restart",!RpgcQuests.activate(doc,failed).ok);
    local dep=RpgcWorldState.copyValue(doc);dep.id="quest.dependent";dep.dependencies=[doc.id];
    record("dependency-unclaimed",!RpgcQuests.activate(dep,failed).ok);
    record("dependency-claimed",RpgcQuests.activate(dep,state).ok);
    local changed=RpgcWorldState.copyValue(doc);changed.rewards[0].value=999;
    record("definition-revision-refused",!RpgcQuests.claim(changed,state,config).ok);
    local invalid=RpgcWorldState.copyValue(doc);invalid.unknown<-true;
    record("unknown-field",!RpgcQuests.checkDefinition(invalid).ok);
    invalid=RpgcWorldState.copyValue(doc);invalid.rewards[0].itemId<-"potion.heal";
    record("wrong-reward-field",!RpgcQuests.checkDefinition(invalid).ok);
    invalid=RpgcWorldState.copyValue(doc);invalid.objectives.append(RpgcWorldState.copyValue(invalid.objectives[0]));
    record("duplicate-objective-id",!RpgcQuests.checkDefinition(invalid).ok);
    invalid=RpgcWorldState.copyValue(doc);invalid.dependencies=[doc.id];
    record("self-dependency",!RpgcQuests.checkDefinition(invalid).ok);

    local counters=RpgcWorldState.copyValue(doc);counters.objectives[0].count=2;
    local counterState=RpgcWorldState.create().value;RpgcQuests.activate(counters,counterState);
    local event1=RpgcWorldState.apply(counterState,{commandId="count.1",kind="consume_object",mapId="village-outskirts",objectName="old_chest"}).value.domainEvents[0];
    local event2=RpgcWorldState.apply(counterState,{commandId="count.2",kind="consume_object",mapId="village-outskirts",objectName="old_chest"}).value.domainEvents[0];
    record("sort-batch-and-dedup",RpgcQuests.consume([counters],counterState,[event2,event1,event1]).ok && counterState.quests.rawget(doc.id).counts.rawget("open-chest")==2);
    local conflict=RpgcWorldState.copyValue(event1);conflict.commandId="different";
    before=RpgcJson.encodeCompact(counterState);
    record("sequence-conflict-atomic",!RpgcQuests.consume([counters],counterState,[conflict]).ok && before==RpgcJson.encodeCompact(counterState));
    local late=RpgcWorldState.copyValue(event1);late.sequence=1;
    record("out-of-order-refused",!RpgcQuests.consume([counters],counterState,[late]).ok);
    local future=RpgcWorldState.copyValue(event1);future.sequence=counterState.revision+1;
    record("future-event-refused",!RpgcQuests.consume([counters],counterState,[future]).ok);
    local missingDefinitionState=RpgcWorldState.create().value;RpgcQuests.activate(doc,missingDefinitionState);
    record("missing-active-definition",!RpgcQuests.consume([],missingDefinitionState,[]).ok);

    local historical=RpgcWorldState.create().value;
    local history=RpgcWorldState.apply(historical,{commandId="history",kind="consume_object",mapId="village-outskirts",objectName="old_chest"}).value.domainEvents;
    RpgcQuests.activate(doc,historical);
    record("already-open-initial-condition",historical.quests.rawget(doc.id).status=="completed" && historical.quests.rawget(doc.id).counts.rawget("open-chest")==1 && historical.gold==0);
    local noInitial=RpgcWorldState.copyValue(doc);noInitial.objectives[0].rawdelete("initialCondition");
    local fresh=RpgcWorldState.create().value;
    local previous=RpgcWorldState.apply(fresh,{commandId="past",kind="consume_object",mapId="village-outskirts",objectName="old_chest"}).value.domainEvents;
    RpgcQuests.activate(noInitial,fresh);
    record("no-implicit-history-count",RpgcQuests.consume([noInitial],fresh,previous).ok && fresh.quests.rawget(doc.id).counts.rawget("open-chest")==0);
    local cycleA=RpgcWorldState.copyValue(doc);cycleA.id="quest.a";cycleA.dependencies=["quest.b"];
    local cycleB=RpgcWorldState.copyValue(doc);cycleB.id="quest.b";cycleB.dependencies=["quest.a"];
    record("dependency-cycle",RpgcQuests.dependencyDiagnostics([cycleA,cycleB]).len()==2);
    cycleB.dependencies=[];
    record("dependency-dag",RpgcQuests.dependencyDiagnostics([cycleA,cycleB]).len()==0);
    record("project-extra-gate",RpgcQuests.extraDiagnostics().len()==0);
    local conditional=RpgcWorldState.copyValue(doc);conditional.condition<-{kind="variable",name="permit",compare="eq",value=1};
    record("activation-condition",!RpgcQuests.activate(conditional,RpgcWorldState.create().value).ok);
    local numeric=RpgcWorldState.copyValue(doc);numeric.objectives[0].eventKind="set_variable";
    numeric.objectives[0].rawset("match",{name="number",value=1.0});numeric.objectives[0].rawdelete("initialCondition");
    local numericState=RpgcWorldState.create().value;RpgcQuests.activate(numeric,numericState);
    local numericEvent=RpgcWorldState.apply(numericState,{kind="set_variable",commandId="numeric",name="number",op="set",value=1});
    record("numeric-match-int-float",RpgcQuests.consume([numeric],numericState,numericEvent.value.domainEvents).ok && numericState.quests.rawget(doc.id).status=="completed");
    local ok=true;foreach(check in checks)if(!check.ok)ok=false;
    return {ok=ok,checks=checks};
}
print("RPGC_QUEST_RESULT="+RpgcJson.encodeCompact(questChecks())+"\n");
