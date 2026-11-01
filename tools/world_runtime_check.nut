// Real-VM regression probes. Keep every fixture in functions, not load.nut locals.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcEventRunner } from "game:/lib/rpgc_event_runner.nut"

function worldEvent(id,steps,repeatable=false) {
    return {schema="eve.rpgc.event",version=1,id=id,repeatable=repeatable,trigger={kind="manual"},steps=steps};
}
function worldCheck(checks,name,ok) { checks.append({name=name,ok=ok}); }
function worldStateChecks(checks) {
    local state=RpgcWorldState.create({gold=10,moment="night"}).value;
    local command={kind="set_variable",commandId="gold.1",name="gold",op="add",value=5};
    local first=RpgcWorldState.apply(state,command);
    local again=RpgcWorldState.apply(state,command);
    worldCheck(checks,"command-dedup",first.ok && again.ok && again.value.duplicate && state.gold==15 && state.revision==1);
    command.value=7;
    worldCheck(checks,"command-conflict",!RpgcWorldState.apply(state,command).ok && state.gold==15);
    local batch=RpgcWorldState.applyBatch(state,[
        {kind="set_variable",commandId="batch.1",name="gold",op="add",value=9},
        {kind="set_variable",commandId="batch.2",name="gold",op="sub",value=100}]);
    worldCheck(checks,"batch-atomic",!batch.ok && state.gold==15 && !state.commandIds.rawin("batch.1"));
    worldCheck(checks,"moment-condition",RpgcWorldState.condition(state,{kind="moment",any=["night"]}).value);
    worldCheck(checks,"unknown-condition",!RpgcWorldState.condition(state,{kind="unknown"}).ok);
    worldCheck(checks,"invalid-compare",!RpgcWorldState.condition(state,{kind="variable",name="gold",value=1,compare="magic"}).ok);
    worldCheck(checks,"reject-bool-number",!RpgcWorldState.create({gold=true}).ok);
    worldCheck(checks,"reject-precision",!RpgcWorldState.create({gold=16777216}).ok);
    local consume=RpgcWorldState.apply(state,{kind="consume_object",commandId="consume.1",mapId="map.one",objectName="chest.one"});
    worldCheck(checks,"consumed-dotted-key",consume.ok && RpgcWorldState.condition(state,{kind="object_consumed",mapId="map.one",objectName="chest.one"}).value);
}
function worldWaitChecks(checks) {
    local state=RpgcWorldState.create().value;
    local event=worldEvent("wait.test",[{kind="wait",duration=1.0},{kind="set_variable",name="gold",op="add",value=3}]);
    local made=RpgcEventRunner.newSession(event,state,{});
    worldCheck(checks,"session-created",made.ok);
    if (!made.ok) return;
    local session=made.value;
    worldCheck(checks,"active-event-refused",!RpgcEventRunner.newSession(event,state,{}).ok);
    local early=RpgcEventRunner.tick(session,state,0.25);
    worldCheck(checks,"wait-not-skipped",early.ok && early.value.status=="waiting" && state.gold==0 && !state.completedEvents.rawin(event.id));
    local done=RpgcEventRunner.tick(session,state,0.75);
    worldCheck(checks,"wait-completes",done.ok && done.value.status=="completed" && state.gold==3 && state.completedEvents.rawget(event.id));
    worldCheck(checks,"completed-event-refused",!RpgcEventRunner.newSession(event,state,{}).ok);
    worldCheck(checks,"repeat-tick-no-reward",RpgcEventRunner.tick(session,state,1.0).ok && state.gold==3);
    local second=RpgcEventRunner.newSession(worldEvent("parallel.test",[
        {kind="parallel",steps=[{kind="wait",duration=1.0},{kind="wait",duration=2.0}]},
        {kind="set_variable",name="gold",op="add",value=4}]),state,{});
    worldCheck(checks,"parallel-created",second.ok);
    if (!second.ok) return;
    worldCheck(checks,"parallel-still-waiting",RpgcEventRunner.tick(second.value,state,1.0).value.status=="waiting" && state.gold==3);
    worldCheck(checks,"parallel-joins-at-max",RpgcEventRunner.tick(second.value,state,1.0).value.status=="completed" && state.gold==7);
}
function worldAckChecks(checks) {
    local state=RpgcWorldState.create({mapId="old"}).value;
    local event=worldEvent("ack.test",[{kind="load_map",mapId="mist-forest",x=4,y=10},
        {kind="message",reference="story.arrival"},{kind="set_variable",name="gold",op="add",value=2}]);
    worldCheck(checks,"capability-missing",!RpgcEventRunner.newSession(event,state,{message=true}).ok && state.activeEvents.len()==0);
    local made=RpgcEventRunner.newSession(event,state,{load_map=true,message=true});
    worldCheck(checks,"ack-session-created",made.ok);
    if (!made.ok) return;
    local session=made.value;
    local sent=RpgcEventRunner.tick(session,state,0.0);
    worldCheck(checks,"request-waits-for-ack",sent.value.requests.len()==1 && state.mapId=="old");
    local id=sent.value.requests[0].operationId;
    worldCheck(checks,"pending-request-not-resent",RpgcEventRunner.tick(session,state,1.0).value.requests.len()==0);
    local transferred=RpgcEventRunner.tick(session,state,0.0,[{operationId=id,ok=true}]);
    worldCheck(checks,"ack-commits-transfer",transferred.ok && state.mapId=="mist-forest" && state.x==4 && transferred.value.requests.len()==1);
    local messageId=transferred.value.requests[0].operationId;
    local duplicate=RpgcEventRunner.tick(session,state,0.0,[{operationId=id,ok=true}]);
    worldCheck(checks,"duplicate-ack-ignored",duplicate.ok && duplicate.value.requests.len()==0 && state.gold==0);
    local done=RpgcEventRunner.tick(session,state,0.0,[{operationId=messageId,ok=true}]);
    worldCheck(checks,"external-completion-reward",done.ok && done.value.status=="completed" && state.gold==2);
}
function worldFailureChecks(checks) {
    local state=RpgcWorldState.create().value;
    local event=worldEvent("failure.test",[{kind="message",reference="story.x"},{kind="set_variable",name="gold",op="add",value=2}]);
    local session=RpgcEventRunner.newSession(event,state,{message=true}).value;
    local sent=RpgcEventRunner.tick(session,state,0.0);
    local failed=RpgcEventRunner.tick(session,state,0.0,[{operationId=sent.value.requests[0].operationId,ok=false,message="renderer failed"}]);
    worldCheck(checks,"external-failure-stops-reward",!failed.ok && session.status=="failed" && state.gold==0 && !state.completedEvents.rawin(event.id));
    local cancellation=RpgcEventRunner.newSession(worldEvent("cancel.test",[{kind="wait",duration=3.0},{kind="set_variable",name="gold",op="add",value=5}]),state,{}).value;
    RpgcEventRunner.tick(cancellation,state,1.0);
    RpgcEventRunner.cancel(cancellation,state);
    worldCheck(checks,"cancel-stops-future-actions",RpgcEventRunner.tick(cancellation,state,5.0).value.status=="cancelled" && state.gold==0);
    local budget=RpgcEventRunner.newSession(worldEvent("budget.test",[
        {kind="set_variable",name="gold",op="add",value=1},
        {kind="set_variable",name="gold",op="add",value=1}]),state,{}, {stepBudget=1}).value;
    local paused=RpgcEventRunner.tick(budget,state,0.0);
    worldCheck(checks,"budget-pauses",paused.ok && paused.value.status=="paused" && state.gold==1);
    worldCheck(checks,"budget-resumes",RpgcEventRunner.tick(budget,state,0.0).value.status=="completed" && state.gold==2);
}
function worldParallelOrdering(checks) {
    local event=worldEvent("parallel.order",[{kind="parallel",steps=[
        {kind="wait",duration=2.0},{kind="wait",duration=1.0}]},
        {kind="set_variable",name="gold",op="set",value=20}]);
    local large=RpgcWorldState.create().value; local small=RpgcWorldState.create().value;
    local a=RpgcEventRunner.newSession(event,large,{});
    local b=RpgcEventRunner.newSession(event,small,{});
    worldCheck(checks,"parallel-order-created",a.ok && b.ok);
    if (!a.ok || !b.ok) return;
    RpgcEventRunner.tick(a.value,large,2.0);
    RpgcEventRunner.tick(b.value,small,1.0);
    worldCheck(checks,"parallel-earliest-deadline-first",small.gold==0 && b.value.root.child.children[1].index==1 && b.value.root.child.children[0].index==0);
    RpgcEventRunner.tick(b.value,small,1.0);
    worldCheck(checks,"parallel-frame-partition-invariant",large.gold==20 && small.gold==20 && large.revision==small.revision);
    local immutable=RpgcWorldState.create().value;
    local original=worldEvent("copy.test",[{kind="wait",duration=1.0},{kind="set_variable",name="gold",op="add",value=3}]);
    local copied=RpgcEventRunner.newSession(original,immutable,{}).value;
    original.steps[1].value=999;
    RpgcEventRunner.tick(copied,immutable,1.0);
    worldCheck(checks,"event-definition-snapshot",immutable.gold==3);
}
function worldAckBoundaryChecks(checks) {
    local state=RpgcWorldState.create().value;
    local event=worldEvent("ack.boundary",[{kind="message",reference="story.x"},{kind="set_variable",name="gold",op="add",value=1}]);
    local session=RpgcEventRunner.newSession(event,state,{message=true}).value;
    local invalid=RpgcEventRunner.tick(session,state,0.0,[{operationId="fake",ok=1}]);
    worldCheck(checks,"invalid-ack-envelope",!invalid.ok && session.root.index==0 && state.clock==0);
    local sent=RpgcEventRunner.tick(session,state,0.0,[{operationId=session.id+"/steps/0",ok=true}]);
    worldCheck(checks,"future-ack-ignored",sent.ok && sent.value.requests.len()==1 && state.gold==0);
    local id=sent.value.requests[0].operationId;
    local done=RpgcEventRunner.tick(session,state,0.0,[{operationId=id,ok=true},{operationId=id,ok=false}]);
    worldCheck(checks,"same-tick-duplicate-ack-first-wins",done.ok && state.gold==1 && done.value.status=="completed");
    local negative=RpgcEventRunner.tick(session,state,-1.0);
    worldCheck(checks,"negative-delta-refused",!negative.ok);
    local far=RpgcWorldState.create({clock=16777214}).value;
    local rangeSession=RpgcEventRunner.newSession(worldEvent("wait.range",[{kind="wait",duration=3.0}]),far,{}).value;
    worldCheck(checks,"wait-overflow-refused",!RpgcEventRunner.tick(rangeSession,far,0.0).ok);
}
function worldRuntimeChecks() {
    local checks=[];
    worldStateChecks(checks); worldWaitChecks(checks); worldAckChecks(checks); worldFailureChecks(checks);
    worldParallelOrdering(checks); worldAckBoundaryChecks(checks);
    local ok=true;
    foreach (check in checks) if (!check.ok) ok=false;
    print("RPGC_WORLD_RUNTIME="+RpgcJson.encodeCompact({ok=ok,checks=checks})+"\n");
}
worldRuntimeChecks();
