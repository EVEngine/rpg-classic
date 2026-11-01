import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcStore } from "game:/lib/rpgc_store.nut"
import { RpgcDialogue } from "game:/lib/rpgc_dialogue.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"

function dialogueChecks() {
    local checks = [];
    local record = function(name, passed) { checks.append({check=name,ok=passed}); };
    local loaded = RpgcJson.parse(RpgcStore.readText("content/dialogues/dialogue.toolkit-guide.json").value);
    record("fixture.parse",loaded.ok); if (!loaded.ok) return {ok=false,checks=checks};
    local doc = loaded.value;
    local state = RpgcWorldState.create().value;
    local started = RpgcDialogue.start(doc,state,"en");
    record("start.strict-schema-and-semantic",started.ok);
    if (!started.ok) return {ok=false,checks=checks,diagnostics=started.diagnostics};
    local session = started.value;
    local first = RpgcDialogue.view(session,state);
    record("line.locale",first.ok && first.value.text == "Welcome to the toolkit proving ground. Will you inspect the old chest outside the village?");
    record("line.cannot-choose",!RpgcDialogue.choose(session,state,"accept",first.value.revision).ok);
    record("advance",RpgcDialogue.advance(session,state,first.value.revision).ok);
    local view = RpgcDialogue.view(session,state);
    record("choice.condition-hidden",view.ok && view.value.options.len()==2 && view.value.options[0].id=="accept");
    record("choice.hidden-cannot-submit",!RpgcDialogue.choose(session,state,"recap",view.value.revision).ok);
    record("choice.unknown-id",!RpgcDialogue.choose(session,state,"bogus",view.value.revision).ok);
    local oldRevision = view.value.revision;
    RpgcWorldState.apply(state,{commandId="test.change",kind="set_variable",name="other",op="set",value=1});
    record("choice.stale-world",!RpgcDialogue.choose(session,state,"accept",oldRevision).ok);
    view = RpgcDialogue.view(session,state);
    record("view.refreshes-revision",view.value.revision>oldRevision);
    record("choice.commit",RpgcDialogue.choose(session,state,"accept",view.value.revision).ok && state.variables.rawget("toolkit.guide.accepted")==1);
    record("choice.duplicate-rejected",!RpgcDialogue.choose(session,state,"accept",view.value.revision).ok);
    local choiceEvents=RpgcDialogue.takeDomainEvents(session);
    record("choice.domain-event",choiceEvents.len()==1 && choiceEvents[0].kind=="set_variable" && choiceEvents[0].payload.name=="toolkit.guide.accepted");
    record("choice.domain-event-drain-once",RpgcDialogue.takeDomainEvents(session).len()==0);
    view = RpgcDialogue.view(session,state,"missing-locale");
    record("locale.fallback",view.ok && view.value.text=="委托已记录：打开村外旧箱子，再按 T 回来领取五枚金币和一份金创药。");
    record("end",RpgcDialogue.advance(session,state,view.value.revision).ok && session.status=="completed");
    record("end.cannot-advance",!RpgcDialogue.advance(session,state,session.revision).ok);
    local cancelled = RpgcDialogue.start(doc,state).value;
    local before = RpgcJson.encodeCompact(state);
    record("cancel",RpgcDialogue.cancel(cancelled).ok && cancelled.status=="cancelled" && before==RpgcJson.encodeCompact(state));
    record("cancel.cannot-advance",!RpgcDialogue.advance(cancelled,state,cancelled.revision).ok);

    local invalid = RpgcJson.deepCopy(doc); invalid.unrecognized <- true;
    record("unknown-document-field",!RpgcDialogue.start(invalid,state).ok);
    invalid = RpgcJson.deepCopy(doc); invalid.nodes[1].options[0].unrecognized <- true;
    record("unknown-option-field",!RpgcDialogue.start(invalid,state).ok);
    invalid = RpgcJson.deepCopy(doc); invalid.nodes[0].next="absent";
    record("missing-next",!RpgcDialogue.start(invalid,state).ok);
    invalid = RpgcJson.deepCopy(doc); invalid.nodes[1].options[1].id="accept";
    record("duplicate-option-id",!RpgcDialogue.start(invalid,state).ok);
    invalid = RpgcJson.deepCopy(doc); invalid.strings[0].key="other";
    record("missing-default-text",!RpgcDialogue.start(invalid,state).ok);
    invalid = RpgcJson.deepCopy(doc); invalid.nodes[0] = {id="greeting",kind="command",next="greeting",commands=[{kind="set_variable",name="bad",op="set",value=1}]};
    before=RpgcJson.encodeCompact(state);
    record("no-wait-cycle",!RpgcDialogue.start(invalid,state).ok && before==RpgcJson.encodeCompact(state));

    local batch = RpgcJson.deepCopy(doc);
    batch.nodes[0] = {id="greeting",kind="command",next="offer",commands=[
        {kind="set_variable",name="atomic.first",op="set",value=7},
        {kind="set_variable",name="gold",op="sub",value=1}]};
    before=RpgcJson.encodeCompact(state);
    record("command-batch-atomic",!RpgcDialogue.start(batch,state).ok && before==RpgcJson.encodeCompact(state));
    batch.nodes[0].commands = [{kind="set_variable",name="atomic.first",op="set",value=7},
        {kind="consume_object",mapId="village",objectName="test-marker"}];
    local committed=RpgcDialogue.start(batch,state);
    record("command-batch-success",committed.ok && state.variables.rawget("atomic.first")==7);
    local consumed=RpgcWorldState.condition(state,{kind="object_consumed",mapId="village",objectName="test-marker"});
    record("consume-shared-state",consumed.ok && consumed.value);
    local batchEvents=RpgcDialogue.takeDomainEvents(committed.value);
    record("command-batch.domain-events",batchEvents.len()==2 && batchEvents[0].kind=="set_variable" && batchEvents[1].kind=="consume_object");
    record("command-batch.domain-events-once",RpgcDialogue.takeDomainEvents(committed.value).len()==0);
    record("references",RpgcDialogue.references(batch).len()==1 && RpgcDialogue.references(batch)[0].id=="village");

    local overflow = RpgcJson.deepCopy(doc);
    overflow.nodes[0] = {id="greeting",kind="command",next="batch2",commands=[]};
    overflow.nodes.append({id="batch2",kind="command",next="batch3",commands=[]});
    overflow.nodes.append({id="batch3",kind="command",next="offer",commands=[]});
    for (local i=0;i<32;i+=1) {
        overflow.nodes[0].commands.append({kind="set_variable",name="budget",op="add",value=1});
        overflow.nodes[4].commands.append({kind="set_variable",name="budget",op="add",value=1});
    }
    overflow.nodes[5].commands.append({kind="set_variable",name="budget",op="add",value=1});
    before=RpgcJson.encodeCompact(state);
    record("command-budget-atomic",!RpgcDialogue.start(overflow,state).ok && before==RpgcJson.encodeCompact(state));
    local loop=RpgcJson.deepCopy(doc); loop.nodes[0].next="greeting";
    local waiting=RpgcDialogue.start(loop,state);
    record("waiting-loop-supported",waiting.ok && RpgcDialogue.advance(waiting.value,state,waiting.value.revision).ok);
    local idsState=RpgcWorldState.create().value;
    local firstSession=RpgcDialogue.start(doc,idsState).value;
    local secondSession=RpgcDialogue.start(doc,idsState).value;
    record("persistent-session-id",firstSession.id!=secondSession.id && idsState.sessionSequence==2);
    local deniedDoc=RpgcJson.deepCopy(doc);
    deniedDoc.nodes[1].options[0].commands.append({kind="set_variable",name="gold",op="sub",value=1});
    local deniedState=RpgcWorldState.create().value;
    local denied=RpgcDialogue.start(deniedDoc,deniedState).value;
    RpgcDialogue.advance(denied,deniedState,denied.revision);
    local deniedBefore=RpgcJson.encodeCompact(deniedState);
    local deniedChoice=RpgcDialogue.choose(denied,deniedState,"accept",denied.revision);
    record("failed-choice.no-domain-events",!deniedChoice.ok && RpgcDialogue.takeDomainEvents(denied).len()==0 && deniedBefore==RpgcJson.encodeCompact(deniedState));
    local advancedDoc=RpgcJson.deepCopy(doc);advancedDoc.nodes[0].next="final-command";
    advancedDoc.nodes.append({id="final-command",kind="command",next="done",commands=[{kind="set_variable",name="advanced",op="set",value=1}]});
    local advancedState=RpgcWorldState.create().value;local advanced=RpgcDialogue.start(advancedDoc,advancedState).value;
    local advancedResult=RpgcDialogue.advance(advanced,advancedState,advanced.revision);
    record("advance.completed-retains-domain-events",advancedResult.ok && advanced.status=="completed" && RpgcDialogue.takeDomainEvents(advanced).len()==1);
    local other=RpgcWorldState.create().value;
    local reSession=RpgcDialogue.start(doc,other).value;
    RpgcDialogue.advance(reSession,other,reSession.revision);
    local shown=RpgcDialogue.view(reSession,other).value;
    // Deliberately violate the revision discipline: choose must still reevaluate.
    other.variables.rawset("toolkit.guide.accepted",1);
    record("choice.reevaluates-condition",!RpgcDialogue.choose(reSession,other,"accept",shown.revision).ok);
    reSession.nodeId="unknown";
    record("unknown-session-node",!RpgcDialogue.view(reSession,other).ok);
    local ok=true; foreach (check in checks) if (!check.ok) ok=false;
    return {ok=ok,checks=checks};
}
local report=dialogueChecks();
print("RPGC_DIALOGUE_RESULT="+RpgcJson.encodeCompact(report)+"\n");
