// Pure shared world state. Commands commit atomically; presentation lives outside.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"

export class RpgcWorldState {}
RpgcWorldState.version <- 1
RpgcWorldState.maxExact <- 16777215

RpgcWorldState._fail <- function(code, message, path = "$") {
    return Rpgc.fail([Rpgc.error(code, message, path, "")]);
}
RpgcWorldState.copyValue <- function(value) {
    if (typeof value == "table") {
        local out = {};
        foreach (key, child in value) out.rawset(key, this.copyValue(child));
        return out;
    }
    if (typeof value == "array") {
        local out = [];
        foreach (child in value) out.append(this.copyValue(child));
        return out;
    }
    return value;
}
RpgcWorldState.safeNumber <- function(value) {
    return Rpgc.isNumber(value) && value == value && value >= -this.maxExact && value <= this.maxExact;
}
RpgcWorldState.safeCounter <- function(value) {
    return this.safeNumber(value) && value >= 0 && value == value.tointeger();
}
RpgcWorldState._name <- function(value) {
    return typeof value == "string" && value.len() > 0;
}
RpgcWorldState.create <- function(config = 0) {
    if (config != 0 && typeof config != "table") return this._fail("world.config", "world config must be a table");
    local state = { variables={}, switches={}, consumed={}, gold=0, mapId="", x=0, y=0,
        facingX=0, facingY=1, moment="", completedEvents={}, commandIds={}, clock=0.0,
        revision=0, sessionSequence=0, activeEvents={}, bag=0, quests={}, questEventCursor=0, questEventIds={} };
    if (typeof config == "table") {
        foreach (key, value in config) {
            if (!state.rawin(key)) return this._fail("world.field", "unknown world field: " + key, "/" + key);
            state.rawset(key, this.copyValue(value));
        }
    }
    foreach (key in ["variables", "switches", "consumed", "completedEvents", "commandIds", "activeEvents", "quests", "questEventIds"]) {
        if (typeof state.rawget(key) != "table") return this._fail("world.shape", key + " must be a table", "/" + key);
    }
    foreach (key, value in state.variables) {
        if (!this._name(key) || key == "gold" || !this.safeNumber(value)) return this._fail("world.variable", "invalid numeric variable", "/variables/" + key);
    }
    foreach (field in ["switches", "consumed", "completedEvents"]) {
        foreach (key, value in state.rawget(field)) {
            if (!this._name(key) || typeof value != "bool") return this._fail("world.flag", "invalid boolean flag", "/" + field);
        }
    }
    foreach (field in ["commandIds", "activeEvents", "questEventIds"]) {
        foreach (key, value in state.rawget(field)) {
            if (!this._name(key) || !this._name(value)) return this._fail("world.identity", "invalid deduplication entry", "/" + field);
        }
    }
    foreach (field in ["gold", "revision", "sessionSequence", "questEventCursor"]) {
        if (!this.safeCounter(state.rawget(field))) return this._fail("world.counter", "counter must be an exact nonnegative integer", "/" + field);
    }
    foreach (field in ["x", "y", "clock"]) {
        if (!this.safeNumber(state.rawget(field)) || state.rawget(field) < 0) return this._fail("world.number", "coordinate/clock must be finite and nonnegative", "/" + field);
    }
    foreach (field in ["mapId", "moment"]) {
        if (typeof state.rawget(field) != "string") return this._fail("world.string", field + " must be a string", "/" + field);
    }
    foreach (field in ["facingX", "facingY"]) {
        local value = state.rawget(field);
        if (!this.safeNumber(value) || value != value.tointeger() || value < -1 || value > 1) return this._fail("world.facing", "facing must be -1, 0 or 1", "/" + field);
    }
    if (state.bag != 0) {
        if (typeof state.bag != "table" || typeof Rpgc.get(state.bag,"slots",0) != "array") return this._fail("world.bag", "bag requires a slots array");
        foreach (stack in state.bag.slots) {
            if (typeof stack != "table" || typeof Rpgc.get(stack,"itemId",0) != "string" || !this.safeCounter(Rpgc.get(stack,"quantity",-1))) return this._fail("world.bag", "invalid inventory stack");
        }
    }
    foreach (id, row in state.quests) {
        if (!Rpgc.validId(id) || typeof row != "table" || typeof Rpgc.get(row,"counts",0) != "table" || typeof Rpgc.get(row,"definitionFingerprint",0) != "string"
            || ["active","completed","claimed","failed"].find(Rpgc.get(row,"status","")) == null
            || !this.safeCounter(Rpgc.get(row,"lastSequence",-1))) return this._fail("world.quest", "invalid quest progress record");
        foreach (objectiveId, count in row.counts) if (!Rpgc.validId(objectiveId) || !this.safeCounter(count)) return this._fail("world.quest", "invalid objective counter");
    }
    return Rpgc.ok(state);
}
RpgcWorldState.condition <- function(state, condition) {
    if (typeof condition != "table") return this._fail("world.condition", "condition must be an object");
    local kind = Rpgc.get(condition, "kind", "");
    if (kind == "always") return Rpgc.ok(true);
    if (kind == "object_consumed") {
        local mapId = Rpgc.get(condition, "mapId", "");
        local name = Rpgc.get(condition, "objectName", "");
        if (!this._name(mapId) || !this._name(name)) return this._fail("world.condition", "object condition needs mapId/objectName");
        local key = mapId + "/" + name;
        return Rpgc.ok(state.consumed.rawin(key) ? state.consumed.rawget(key) : false);
    }
    if (kind == "switch") {
        local name = Rpgc.get(condition, "name", "");
        if (!this._name(name)) return this._fail("world.condition", "switch condition needs name");
        return Rpgc.ok(state.switches.rawin(name) ? state.switches.rawget(name) : false);
    }
    if (kind == "moment") {
        local any = Rpgc.get(condition, "any", 0);
        if (typeof any != "array" || any.len() == 0) return this._fail("world.condition", "moment condition needs nonempty any array");
        if (state.moment == "") return this._fail("runtime.capability-missing", "world moment has not been supplied");
        local matched = false;
        foreach (name in any) {
            if (!this._name(name)) return this._fail("world.condition", "moment names must be nonempty strings");
            if (name == state.moment) matched = true;
        }
        return Rpgc.ok(matched);
    }
    if (kind == "variable") {
        local name = Rpgc.get(condition, "name", "");
        local want = Rpgc.get(condition, "value", null);
        local compare = Rpgc.get(condition, "compare", "eq");
        if (!this._name(name) || !this.safeNumber(want)) return this._fail("world.condition", "variable condition needs name and finite numeric value");
        local have = name == "gold" ? state.gold : (state.variables.rawin(name) ? state.variables.rawget(name) : 0);
        if (compare == "eq") return Rpgc.ok(have == want);
        if (compare == "ne") return Rpgc.ok(have != want);
        if (compare == "lt") return Rpgc.ok(have < want);
        if (compare == "lte") return Rpgc.ok(have <= want);
        if (compare == "gt") return Rpgc.ok(have > want);
        if (compare == "gte") return Rpgc.ok(have >= want);
        return this._fail("world.condition-compare", "unknown comparison: " + compare);
    }
    return this._fail("world.condition-kind", "unsupported condition kind: " + kind);
}
RpgcWorldState.itemContext <- function(state, config, itemId) {
    if (typeof state.bag != "table" || typeof config != "table" || typeof Rpgc.get(config,"items",0) != "table") return this._fail("runtime.capability-missing", "give_item requires world bag and item configuration");
    local bag=state.bag;
    if (typeof Rpgc.get(bag,"slots",0)!="array" || !this.safeCounter(Rpgc.get(bag,"slotCount",-1)) || bag.slotCount!=bag.slots.len()
        || Rpgc.get(bag,"stackRule","")!="sameItem") return this._fail("world.item-config", "invalid bag shape or unsupported stack rule");
    foreach(field in ["maxWeight","maxVolume"])if(!this.safeNumber(Rpgc.get(bag,field,-1)) || bag.rawget(field)<0)return this._fail("world.item-config", "bag limits must be finite and nonnegative");
    foreach(id,definition in config.items) {
        if(typeof definition!="table" || Rpgc.get(definition,"id","")!=id || !this.safeCounter(Rpgc.get(definition,"maxStack",0)) || definition.maxStack<1)return this._fail("world.item-config", "item catalogue requires matching ids and exact positive maxStack");
        foreach(field in ["weight","volume"]) {
            local value=Rpgc.get(definition,field,0);
            if(!this.safeNumber(value) || value<0)return this._fail("world.item-config", "item dimensions must be finite and nonnegative");
        }
    }
    if(!config.items.rawin(itemId))return this._fail("world.item-config", "item is missing from catalogue");
    foreach(stack in bag.slots) {
        if(typeof stack!="table" || typeof Rpgc.get(stack,"itemId",0)!="string" || !this.safeCounter(Rpgc.get(stack,"quantity",-1)))return this._fail("world.item-config", "invalid bag stack");
        if(stack.itemId=="") {if(stack.quantity!=0)return this._fail("world.item-config", "empty stack has nonzero quantity");}
        else if(!config.items.rawin(stack.itemId) || stack.quantity<1 || stack.quantity>config.items.rawget(stack.itemId).maxStack)return this._fail("world.item-config", "bag stack is unknown or outside stack bounds");
    }
    return Rpgc.ok(true);
}
RpgcWorldState._applyOne <- function(state, command, itemConfig = 0) {
    if (typeof command != "table") return this._fail("world.command", "command must be an object");
    local id = Rpgc.get(command, "commandId", "");
    local kind = Rpgc.get(command, "kind", "");
    if (!this._name(id)) return this._fail("world.command-id", "command requires a nonempty commandId");
    local signature = RpgcJson.encodeCompact(command);
    if (state.commandIds.rawin(id)) {
        if (state.commandIds.rawget(id) != signature) return this._fail("world.command-conflict", "commandId was already used with different parameters");
        return Rpgc.ok({duplicate=true, domainEvents=[]});
    }
    if (!this.safeCounter(state.revision + 1)) return this._fail("world.precision", "world revision exceeds exact counter range");
    if (kind == "set_variable") {
        local name = Rpgc.get(command, "name", "");
        local op = Rpgc.get(command, "op", "set");
        local value = Rpgc.get(command, "value", null);
        if (!this._name(name) || !this.safeNumber(value)) return this._fail("world.variable", "variable command requires name and finite numeric value");
        if (op == "switchOn" || op == "switchOff") state.switches.rawset(name, op == "switchOn");
        else {
            local current = name == "gold" ? state.gold : (state.variables.rawin(name) ? state.variables.rawget(name) : 0);
            local next = value;
            if (op == "add") next = current + value;
            else if (op == "sub") next = current - value;
            else if (op != "set") return this._fail("world.variable-op", "unknown variable operation");
            if (!this.safeNumber(next) || (name == "gold" && !this.safeCounter(next))) return this._fail("world.precision", "variable result is outside supported numeric range");
            if (name == "gold") state.gold = next;
            else state.variables.rawset(name, next);
        }
    } else if (kind == "give_item") {
        local itemId = Rpgc.get(command,"itemId",""); local quantity = Rpgc.get(command,"quantity",0);
        if (!this._name(itemId) || !this.safeCounter(quantity) || quantity < 1) return this._fail("world.item", "give_item requires itemId and exact positive quantity");
        local context = this.itemContext(state,itemConfig,itemId);
        if (!context.ok) return context;
        local capacity = RpgcItems.canAdd(state.bag,itemConfig,itemId,quantity);
        if (!capacity.ok) return capacity;
        local added = RpgcItems.add(state.bag,itemConfig,itemId,quantity);
        if (!added.ok) return added;
        if (added.value.remaining != 0) return this._fail("world.item-partial", "item reward did not fit completely");
    } else if (kind == "consume_object") {
        local mapId = Rpgc.get(command, "mapId", "");
        local name = Rpgc.get(command, "objectName", "");
        if (!this._name(mapId) || !this._name(name)) return this._fail("world.object", "consume_object needs mapId/objectName");
        state.consumed.rawset(mapId + "/" + name, true);
    } else if (kind == "transfer") {
        local mapId = Rpgc.get(command, "mapId", "");
        local x = Rpgc.get(command, "x", null);
        local y = Rpgc.get(command, "y", null);
        if (!this._name(mapId) || !this.safeNumber(x) || !this.safeNumber(y) || x < 0 || y < 0) return this._fail("world.transfer", "transfer requires mapId and nonnegative coordinates");
        state.mapId = mapId; state.x = x; state.y = y;
        foreach (field in ["facingX", "facingY"]) {
            local value = Rpgc.get(command, field, state.rawget(field));
            if (!this.safeNumber(value) || value != value.tointeger() || value < -1 || value > 1) return this._fail("world.facing", "invalid facing direction");
            state.rawset(field, value);
        }
    } else if (kind == "face") {
        foreach (field in ["facingX", "facingY"]) {
            local value = Rpgc.get(command, field, null);
            if (!this.safeNumber(value) || value != value.tointeger() || value < -1 || value > 1) return this._fail("world.facing", "face requires facingX/facingY in -1..1");
            state.rawset(field, value);
        }
    } else if (kind == "set_moment") {
        local moment = Rpgc.get(command, "moment", "");
        if (!this._name(moment)) return this._fail("world.moment", "set_moment requires a nonempty moment");
        state.moment = moment;
    } else return this._fail("world.command-kind", "unsupported world command: " + kind);
    state.revision += 1;
    state.commandIds.rawset(id, signature);
    return Rpgc.ok({duplicate=false, domainEvents=[{sequence=state.revision, commandId=id, kind=kind, payload=this.copyValue(command)}]});
}
RpgcWorldState.applyBatch <- function(state, commands, itemConfig = 0) {
    if (typeof commands != "array" || commands.len() > 4096) return this._fail("world.batch", "commands must be an array with at most 4096 entries");
    local candidate = this.copyValue(state);
    local events = []; local duplicate = true;
    foreach (command in commands) {
        local applied = this._applyOne(candidate, command, itemConfig);
        if (!applied.ok) return applied;
        if (!applied.value.duplicate) duplicate = false;
        foreach (event in applied.value.domainEvents) events.append(event);
    }
    foreach (key, value in candidate) state.rawset(key, value);
    return Rpgc.ok({state=state, domainEvents=events, duplicate=duplicate});
}
RpgcWorldState.apply <- function(state, command, itemConfig = 0) {
    return this.applyBatch(state, [command], itemConfig);
}
