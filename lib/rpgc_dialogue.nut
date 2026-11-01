// Pure dialogue sessions. World commands/conditions have one authority.
import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcStore } from "./rpgc_store.nut"
import { RpgcSystems } from "./rpgc_systems.nut"
import { RpgcWorldState } from "./rpgc_world_state.nut"

export class RpgcDialogue {}
RpgcDialogue.version <- 1
RpgcDialogue.kinds <- ["dialogue"]
RpgcDialogue.budget <- 64

RpgcDialogue.failure <- function(code, message, path = "$") {
    return Rpgc.fail([Rpgc.error("dialogue." + code, message, path, "")]);
}
RpgcDialogue.nodeOf <- function(doc, id) {
    foreach (node in doc.nodes) if (node.id == id) return node;
    return 0;
}
RpgcDialogue.textOf <- function(doc, key, locale) {
    local fallback = null;
    foreach (row in doc.strings) {
        if (row.key != key) continue;
        if (row.locale == locale) return row.text;
        if (row.locale == doc.defaultLocale) fallback = row.text;
    }
    return fallback;
}
RpgcDialogue.commandDiagnostics <- function(commands, at, diagnostics) {
    for (local i = 0; i < commands.len(); i += 1) {
        local c = commands[i]; local pointer = at + "/" + i;
        local allowed = c.kind == "set_variable" ? ["kind", "name", "op", "value"] : ["kind", "mapId", "objectName"];
        foreach (key, value in c) if (allowed.find(key) == null)
            diagnostics.append(Rpgc.error("dialogue.command-field", "field does not belong to command kind", pointer + "/" + key, ""));
        local required = c.kind == "set_variable" ? ["name", "op"] : ["mapId", "objectName"];
        foreach (key in required) if (Rpgc.asString(Rpgc.get(c, key, "")) == "")
            diagnostics.append(Rpgc.error("dialogue.command-required", "command requires " + key, pointer, ""));
        if (c.kind == "set_variable" && ["set", "add", "sub"].find(Rpgc.get(c,"op","")) != null && !c.rawin("value"))
            diagnostics.append(Rpgc.error("dialogue.command-value", "numeric operation requires value", pointer, ""));
    }
    return diagnostics;
}
RpgcDialogue.semanticDiagnostics <- function(doc) {
    local diagnostics = []; local ids = {}; local strings = {};
    if (!Rpgc.validId(doc.id)) diagnostics.append(Rpgc.error("dialogue.id", "invalid dialogue id", "/id", ""));
    if (!Rpgc.validId(doc.defaultLocale)) diagnostics.append(Rpgc.error("dialogue.locale", "invalid default locale", "/defaultLocale", ""));
    for (local i = 0; i < doc.strings.len(); i += 1) {
        local row = doc.strings[i]; local key = row.locale + "/" + row.key;
        if (!Rpgc.validId(row.key) || !Rpgc.validId(row.locale) || strings.rawin(key))
            diagnostics.append(Rpgc.error("dialogue.string-key", "invalid or duplicate locale/text key", "/strings/" + i, ""));
        strings.rawset(key, true);
    }
    for (local i = 0; i < doc.nodes.len(); i += 1) {
        local node = doc.nodes[i]; local at = "/nodes/" + i;
        if (!Rpgc.validId(node.id) || ids.rawin(node.id))
            diagnostics.append(Rpgc.error("dialogue.node-id", "invalid or duplicate node id", at + "/id", ""));
        ids.rawset(node.id, node);
        local allowed = ["id", "kind"];
        if (node.kind == "line") allowed.extend(["speaker", "textKey", "next"]);
        if (node.kind == "choice") allowed.extend(["speaker", "textKey", "options"]);
        if (node.kind == "command") allowed.extend(["commands", "next"]);
        foreach (key, value in node) if (allowed.find(key) == null)
            diagnostics.append(Rpgc.error("dialogue.node-field", "field does not belong to node kind", at + "/" + key, ""));
        if (node.kind == "line" || node.kind == "choice") {
            local key = Rpgc.asString(Rpgc.get(node,"textKey",""));
            if (key == "" || !strings.rawin(doc.defaultLocale + "/" + key))
                diagnostics.append(Rpgc.error("dialogue.missing-text", "node needs a default-locale text key", at + "/textKey", ""));
        }
        if (node.kind == "command") {
            if (!node.rawin("commands") || node.commands.len() == 0)
                diagnostics.append(Rpgc.error("dialogue.commands", "command node requires commands", at, ""));
            diagnostics = this.commandDiagnostics(Rpgc.get(node,"commands",[]), at + "/commands", diagnostics);
        }
        if (node.kind == "choice") {
            local options = Rpgc.get(node,"options",[]); local seen = {};
            if (options.len() == 0) diagnostics.append(Rpgc.error("dialogue.options", "choice requires options", at, ""));
            for (local k = 0; k < options.len(); k += 1) {
                local option = options[k]; local oat = at + "/options/" + k;
                if (!Rpgc.validId(option.id) || seen.rawin(option.id))
                    diagnostics.append(Rpgc.error("dialogue.option-id", "invalid or duplicate option id", oat + "/id", ""));
                seen.rawset(option.id, true);
                if (!strings.rawin(doc.defaultLocale + "/" + option.textKey))
                    diagnostics.append(Rpgc.error("dialogue.missing-text", "option needs default-locale text", oat + "/textKey", ""));
                if (option.rawin("condition")) diagnostics = RpgcSystems.conditionDiagnostics(option.condition, oat + "/condition", RpgcSystems.momentTable(), diagnostics);
                diagnostics = this.commandDiagnostics(Rpgc.get(option,"commands",[]), oat + "/commands", diagnostics);
            }
        }
    }
    if (!ids.rawin(doc.entry)) diagnostics.append(Rpgc.error("dialogue.entry", "entry node is missing", "/entry", ""));
    for (local i = 0; i < doc.nodes.len(); i += 1) {
        local node = doc.nodes[i]; local at = "/nodes/" + i; local targets = [];
        if (node.kind == "line" || node.kind == "command") targets.append(Rpgc.get(node,"next",""));
        foreach (option in Rpgc.get(node,"options",[])) targets.append(option.next);
        foreach (target in targets) if (!ids.rawin(target))
            diagnostics.append(Rpgc.error("dialogue.next", "next node is missing: " + target, at, ""));
        if (node.kind != "command") continue;
        local visited = {}; local cursor = node.id; local steps = 0;
        while (ids.rawin(cursor) && ids.rawget(cursor).kind == "command") {
            if (visited.rawin(cursor) || steps >= this.budget) {
                diagnostics.append(Rpgc.error("dialogue.no-wait-cycle", "command chain loops or exceeds budget", at, ""));
                break;
            }
            visited.rawset(cursor,true); steps += 1;
            cursor = Rpgc.get(ids.rawget(cursor),"next","");
        }
    }
    return diagnostics;
}
RpgcDialogue.references <- function(doc) {
    local out = [];
    for (local i = 0; i < doc.nodes.len(); i += 1) {
        local node = doc.nodes[i]; local at = "/nodes/" + i;
        this.commandRefs(Rpgc.get(node,"commands",[]), at + "/commands", out);
        local options = Rpgc.get(node,"options",[]);
        for (local k = 0; k < options.len(); k += 1) {
            local option = options[k]; local oat = at + "/options/" + k;
            this.commandRefs(Rpgc.get(option,"commands",[]), oat + "/commands", out);
            local c = Rpgc.get(option,"condition",{});
            if (Rpgc.get(c,"kind","") == "object_consumed") out.append({kind="map",id=c.mapId,path=oat+"/condition/mapId"});
        }
    }
    return out;
}
RpgcDialogue.commandRefs <- function(commands, at, out) {
    for (local i = 0; i < commands.len(); i += 1) if (commands[i].kind == "consume_object")
        out.append({kind="map",id=commands[i].mapId,path=at+"/"+i+"/mapId"});
}
RpgcDialogue.checkDefinition <- function(doc) {
    foreach (name in ["condition", "dialogue"]) {
        local read = RpgcStore.readText("schema/eve.rpgc." + name + ".json");
        if (!read.ok) return read;
        local registered = eve.Schema().registerJson(read.value);
        if (!registered.ok) return this.failure("schema-register", "cannot register " + name);
    }
    local checked = eve.Schema().validateJson("eve.rpgc.dialogue", RpgcJson.encodeCompact(doc));
    if (!checked.ok) return this.failure("schema", "dialogue definition violates its strict schema");
    return Rpgc.result(doc, this.semanticDiagnostics(doc));
}
RpgcDialogue.moveTo <- function(session, state, next, initialCommands) {
    if (session.revision >= 1000000) return this.failure("revision-limit", "session revision limit reached");
    local commands = RpgcJson.deepCopy(initialCommands); local cursor = next; local seen = {}; local steps = 0;
    local node = 0;
    while (true) {
        node = this.nodeOf(session.document, cursor);
        if (node == 0) return this.failure("unknown-node", "unknown node: " + cursor);
        if (node.kind != "command") break;
        if (seen.rawin(cursor) || steps >= this.budget) return this.failure("budget", "command chain loops or exceeds budget");
        seen.rawset(cursor,true); steps += 1;
        commands.extend(RpgcJson.deepCopy(node.commands)); cursor = node.next;
    }
    if (["line","choice","end"].find(node.kind) == null) return this.failure("unknown-node", "unsupported node kind");
    if (commands.len() > this.budget || session.commandSeq + commands.len() > 1000000)
        return this.failure("budget", "command batch exceeds budget");
    local sequence = session.commandSeq;
    foreach (command in commands) { sequence += 1; command.commandId <- session.id + "." + sequence; }
    local emittedEvents = [];
    if (commands.len() > 0) {
        local applied = RpgcWorldState.applyBatch(state, commands);
        if (!applied.ok) return applied;
        emittedEvents = applied.value.domainEvents;
    }
    local pending = Rpgc.get(session,"pendingDomainEvents",[]);
    foreach (event in emittedEvents) pending.append(event);
    session.pendingDomainEvents <- pending;
    session.nodeId = cursor; session.commandSeq = sequence;
    session.status = node.kind == "end" ? "completed" : "active";
    session.stateRevision = state.revision; session.revision += 1;
    return Rpgc.ok(session);
}
RpgcDialogue.start <- function(doc, state, locale = "") {
    local checked = this.checkDefinition(doc); if (!checked.ok) return checked;
    if (typeof state != "table" || !state.rawin("revision")) return this.failure("state", "shared world state is required");
    if (!RpgcWorldState.safeCounter(state.sessionSequence + 1)) return this.failure("session-limit", "session id budget exhausted");
    local candidate = RpgcWorldState.copyValue(state); candidate.sessionSequence += 1;
    local session = {id="dialogue."+candidate.sessionSequence, document=RpgcJson.deepCopy(doc), nodeId=doc.entry,
        revision=0, stateRevision=state.revision, commandSeq=0, status="active", pendingDomainEvents=[],
        locale=locale == "" ? doc.defaultLocale : locale};
    local moved = this.moveTo(session,candidate,doc.entry,[]);
    if (!moved.ok) return moved;
    foreach (key,value in candidate) state.rawset(key,value);
    return moved;
}
RpgcDialogue.view <- function(session, state, locale = "") {
    if (locale == "") locale = session.locale;
    if (session.stateRevision != state.revision || locale != session.locale) {
        if (session.revision >= 1000000) return this.failure("revision-limit", "session revision limit reached");
        session.revision += 1; session.stateRevision = state.revision; session.locale = locale;
    }
    local node = this.nodeOf(session.document, session.nodeId);
    if (node == 0) return this.failure("unknown-node", "session node is missing");
    local rendered = {dialogueId=session.document.id,nodeId=node.id,kind=node.kind,
        speaker=Rpgc.get(node,"speaker",""),textKey=Rpgc.get(node,"textKey",""),text="",
        options=[],revision=session.revision,status=session.status};
    if (session.status != "active") return Rpgc.ok(rendered);
    local text = this.textOf(session.document,rendered.textKey,locale);
    if (text == null) return this.failure("missing-text", "no requested/default text for " + rendered.textKey);
    rendered.text = text;
    foreach (option in Rpgc.get(node,"options",[])) {
        if (option.rawin("condition")) {
            local allowed = RpgcWorldState.condition(state,option.condition);
            if (!allowed.ok) return allowed;
            if (!allowed.value) continue;
        }
        local optionText = this.textOf(session.document,option.textKey,locale);
        if (optionText == null) return this.failure("missing-text", "no option fallback text");
        rendered.options.append({id=option.id,textKey=option.textKey,text=optionText});
    }
    return Rpgc.ok(rendered);
}
RpgcDialogue.ready <- function(session,state,expectedRevision) {
    if (session.status != "active") return this.failure("inactive", "session is not active");
    if (typeof expectedRevision != "integer" || expectedRevision != session.revision || session.stateRevision != state.revision)
        return this.failure("stale-revision", "refresh view before submitting this choice/advance");
    return Rpgc.ok(true);
}
RpgcDialogue.choose <- function(session,state,optionId,expectedRevision) {
    local ready = this.ready(session,state,expectedRevision); if (!ready.ok) return ready;
    local node = this.nodeOf(session.document,session.nodeId);
    if (node == 0 || node.kind != "choice") return this.failure("not-choice", "session is not at a choice");
    foreach (option in node.options) {
        if (option.id != optionId) continue;
        if (option.rawin("condition")) {
            local allowed = RpgcWorldState.condition(state,option.condition);
            if (!allowed.ok) return allowed;
            if (!allowed.value) return this.failure("hidden-option", "option condition is no longer true");
        }
        return this.moveTo(session,state,option.next,Rpgc.get(option,"commands",[]));
    }
    return this.failure("unknown-option", "unknown option id");
}
RpgcDialogue.advance <- function(session,state,expectedRevision) {
    local ready = this.ready(session,state,expectedRevision); if (!ready.ok) return ready;
    local node = this.nodeOf(session.document,session.nodeId);
    if (node == 0 || node.kind != "line") return this.failure("not-line", "only line nodes can advance");
    return this.moveTo(session,state,node.next,[]);
}
RpgcDialogue.cancel <- function(session) {
    if (session.status != "active") return this.failure("inactive", "only an active session can cancel");
    if (session.revision >= 1000000) return this.failure("revision-limit", "session revision limit reached");
    session.status = "cancelled"; session.revision += 1;
    return Rpgc.ok(session);
}

// Consume committed command events before disposing a completed session.
RpgcDialogue.takeDomainEvents <- function(session) {
    local events = Rpgc.get(session,"pendingDomainEvents",[]);
    session.pendingDomainEvents <- [];
    return events;
}
