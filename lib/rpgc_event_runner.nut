// Cooperative event-v1 interpreter. Effects outside world state require an ack.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcValidate } from "game:/lib/rpgc_validate.nut"

export class RpgcEventRunner {}
RpgcEventRunner.version <- 1

RpgcEventRunner._sequence <- function(steps, path, at) {
    return {steps=steps, path=path, index=0, child=0, at=at};
}
RpgcEventRunner._capabilities <- function(steps, capabilities, diagnostics, path) {
    for (local i=0; i<steps.len(); i+=1) {
        local step=steps[i]; local kind=step.kind; local at=path+"/"+i;
        if (kind == "parallel") this._capabilities(step.steps, capabilities, diagnostics, at+"/steps");
        else if (kind == "branch") {
            this._capabilities(step.then, capabilities, diagnostics, at+"/then");
            this._capabilities(Rpgc.get(step,"else",[]), capabilities, diagnostics, at+"/else");
        } else if (kind != "wait" && kind != "set_variable" && kind != "consume_object") {
            if (!capabilities.rawin(kind) || capabilities.rawget(kind) != true) diagnostics.append(
                Rpgc.error("runtime.capability-missing", "host cannot perform " + kind, at, "provide an acknowledged presentation adapter"));
        }
    }
}
RpgcEventRunner.newSession <- function(event, state, capabilities, options=0) {
    if (typeof capabilities != "table") return RpgcWorldState._fail("runtime.capabilities", "capabilities must be a table");
    local validated=RpgcValidate.validateDocument("event",event);
    if (!validated.ok) return validated;
    local diagnostics=[];
    this._capabilities(event.steps,capabilities,diagnostics,"/steps");
    if (diagnostics.len()>0) return Rpgc.fail(diagnostics);
    local repeatable=Rpgc.get(event,"repeatable",false);
    if (!repeatable && state.completedEvents.rawin(event.id) && state.completedEvents.rawget(event.id)) return RpgcWorldState._fail("runtime.event-completed","nonrepeatable event already completed");
    if (state.activeEvents.rawin(event.id)) return RpgcWorldState._fail("runtime.event-active","event already has an active session");
    local budget=Rpgc.get(options,"stepBudget",128);
    if (!RpgcWorldState.safeCounter(budget) || budget<1 || budget>4096) return RpgcWorldState._fail("runtime.budget","stepBudget must be 1..4096");
    if (!RpgcWorldState.safeCounter(state.sessionSequence+1)) return RpgcWorldState._fail("world.precision","session sequence exhausted");
    state.sessionSequence+=1;
    local id="event."+state.sessionSequence;
    local copied=RpgcWorldState.copyValue(event);
    local session={id=id,eventId=event.id,repeatable=repeatable,status="running",time=state.clock,
        stepBudget=budget,root=this._sequence(copied.steps,"/steps",state.clock),operations={},diagnostics=[]};
    state.activeEvents.rawset(event.id,id);
    return Rpgc.ok(session);
}
RpgcEventRunner._release <- function(session,state) {
    if (state.activeEvents.rawin(session.eventId) && state.activeEvents.rawget(session.eventId)==session.id) state.activeEvents.rawdelete(session.eventId);
}
RpgcEventRunner.cancel <- function(session,state) {
    if (session.status=="completed" || session.status=="failed" || session.status=="cancelled") return Rpgc.ok({requests=[],domainEvents=[],status=session.status});
    session.status="cancelled";
    this._release(session,state);
    return Rpgc.ok({requests=[],domainEvents=[],status=session.status});
}
RpgcEventRunner._failure <- function(context,result) {
    context.failed=true;
    foreach (diagnostic in result.diagnostics) context.diagnostics.append(diagnostic);
}
RpgcEventRunner._commit <- function(state,command,context) {
    local applied=RpgcWorldState.apply(state,command);
    if (!applied.ok) { this._failure(context,applied); return false; }
    foreach (event in applied.value.domainEvents) context.domainEvents.append(event);
    return true;
}
RpgcEventRunner._advance <- function(sequence,session,state,now,context) {
    while (sequence.index<sequence.steps.len() && !context.failed) {
        local path=sequence.path+"/"+sequence.index;
        local step=sequence.steps[sequence.index];
        local kind=step.kind;
        if (sequence.child==0) {
            if (context.remaining<=0) { context.exhausted=true; return false; }
            context.remaining-=1;
            if (kind=="wait") {
                local due=sequence.at+step.duration;
                if (!RpgcWorldState.safeNumber(due)) {
                    this._failure(context,RpgcWorldState._fail("world.precision","wait deadline exceeds logical clock range",path));
                    return false;
                }
                sequence.child={mode="wait",due=due};
            }
            else if (kind=="parallel") {
                local children=[];
                for (local i=0;i<step.steps.len();i+=1) children.append(this._sequence([step.steps[i]],path+"/steps/"+i,sequence.at));
                sequence.child={mode="parallel",children=children};
            } else if (kind=="branch") {
                local checked=RpgcWorldState.condition(state,step.condition);
                if (!checked.ok) { this._failure(context,checked); return false; }
                local chosen=checked.value ? step.then : Rpgc.get(step,"else",[]);
                sequence.child={mode="branch",sequence=this._sequence(chosen,path+(checked.value ? "/then" : "/else"),sequence.at)};
            } else if (kind=="set_variable" || kind=="consume_object") {
                local command=RpgcWorldState.copyValue(step);
                command.commandId<-session.id+path;
                if (!this._commit(state,command,context)) return false;
                sequence.index+=1;
                continue;
            } else {
                local operationId=session.id+path;
                local child={mode="external",operationId=operationId,done=false,at=now,step=step};
                sequence.child=child;
                session.operations.rawset(operationId,child);
                context.requests.append({operationId=operationId,kind=kind,step=RpgcWorldState.copyValue(step),path=path});
            }
        }
        local child=sequence.child;
        if (child.mode=="wait") {
            if (child.due>now) return false;
            sequence.at=child.due;
        } else if (child.mode=="branch") {
            if (!this._advance(child.sequence,session,state,now,context)) return false;
            sequence.at=child.sequence.at;
        } else if (child.mode=="parallel") {
            local allDone=true; local finishedAt=sequence.at;
            foreach (task in child.children) {
                if (!this._advance(task,session,state,now,context)) allDone=false;
                if (context.failed) return false;
                if (task.at>finishedAt) finishedAt=task.at;
            }
            if (!allDone) return false;
            sequence.at=finishedAt;
        } else {
            if (!child.done) return false;
            if (kind=="load_map") {
                local command={kind="transfer",commandId=child.operationId+"/commit",mapId=step.mapId,x=step.x,y=step.y};
                if (!this._commit(state,command,context)) return false;
            } else if (kind=="face_actor" && step.actorId=="player") {
                local command={kind="face",commandId=child.operationId+"/commit",facingX=step.facingX,facingY=step.facingY};
                if (!this._commit(state,command,context)) return false;
            }
            sequence.at=child.at;
        }
        sequence.child=0;
        sequence.index+=1;
    }
    return !context.failed && sequence.index>=sequence.steps.len();
}
// Find the next pending logical deadline. Ticks advance through deadlines so
// parallel state actions have the same order for one large dt and many small dt.
RpgcEventRunner._nextDue <- function(sequence, after) {
    if (sequence.child==0) return null;
    local child=sequence.child;
    if (child.mode=="wait") return child.due>after ? child.due : null;
    if (child.mode=="branch") return this._nextDue(child.sequence,after);
    if (child.mode!="parallel") return null;
    local next=null;
    foreach (task in child.children) {
        local due=this._nextDue(task,after);
        if (due!=null && (next==null || due<next)) next=due;
    }
    return next;
}
RpgcEventRunner.tick <- function(session,state,dt,acks=[]) {
    if (!RpgcWorldState.safeNumber(dt) || dt<0 || !RpgcWorldState.safeNumber(session.time+dt)) return RpgcWorldState._fail("runtime.delta","logical delta must be finite, nonnegative and within range");
    if (typeof acks!="array") return RpgcWorldState._fail("runtime.ack","acknowledgements must be an array");
    if (session.status=="completed" || session.status=="cancelled" || session.status=="failed") return Rpgc.result({requests=[],domainEvents=[],status=session.status},session.diagnostics);
    // Validate the complete input envelope before accepting any acknowledgements.
    foreach (ack in acks) {
        if (typeof ack!="table" || typeof Rpgc.get(ack,"operationId",0)!="string" || typeof Rpgc.get(ack,"ok",0)!="bool") return RpgcWorldState._fail("runtime.ack","ack requires operationId string and ok boolean");
    }
    local previous=session.time;
    local target=previous+dt;
    local context={remaining=session.stepBudget,exhausted=false,failed=false,requests=[],domainEvents=[],diagnostics=[]};
    // Only requests issued on an earlier tick may receive acknowledgements.
    local accepted=[]; local seenAcks={};
    foreach (ack in acks) {
        local id=ack.operationId;
        if (seenAcks.rawin(id) || !session.operations.rawin(id) || session.operations.rawget(id).done) {
            context.diagnostics.append(Rpgc.note("runtime.ack-ignored","late, duplicate or unknown acknowledgement",id,""));
            continue;
        }
        seenAcks.rawset(id,true);
        if (!ack.ok) {
            context.failed=true;
            context.diagnostics.append(Rpgc.error("runtime.external-failed",Rpgc.get(ack,"message","host operation failed"),id,"already committed external effects are not rolled back"));
            break;
        }
        accepted.append(ack);
    }
    local finished=false;
    if (!context.failed) {
        finished=this._advance(session.root,session,state,previous,context);
        local cursor=previous;
        while (!finished && !context.failed && !context.exhausted) {
            local next=this._nextDue(session.root,cursor);
            if (next==null || next>target) break;
            cursor=next;
            finished=this._advance(session.root,session,state,cursor,context);
        }
        foreach (ack in accepted) {
            local operation=session.operations.rawget(ack.operationId);
            if (operation.done) {
                context.diagnostics.append(Rpgc.note("runtime.ack-ignored","duplicate acknowledgement",ack.operationId,""));
                continue;
            }
            operation.done=true;
            operation.at=target;
        }
        if (!finished && !context.failed && !context.exhausted) finished=this._advance(session.root,session,state,target,context);
    }
    session.time=target;
    if (session.time>state.clock) state.clock=session.time;
    if (context.failed) {
        session.status="failed";
        context.requests=[];
        session.diagnostics=context.diagnostics;
        this._release(session,state);
    } else if (finished) {
        session.status="completed";
        state.completedEvents.rawset(session.eventId,true);
        this._release(session,state);
    } else if (context.exhausted) {
        session.status="paused";
        context.diagnostics.append(Rpgc.warn("runtime.step-budget","tick step budget exhausted; resume explicitly with the next tick","/steps",""));
    } else session.status="waiting";
    return Rpgc.result({requests=context.requests,domainEvents=context.domainEvents,status=session.status},context.diagnostics);
}
