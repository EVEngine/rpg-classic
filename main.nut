// Default `eve run .` entry: play the authored maps.
//
// Editors stay under `apps/{tilemap,skill,event}`. This file is the runtime
// adapter described in docs/04-runtime-integration.md: documents remain the
// source of truth, and this script only projects them into Map / Pathfinder.

// The toolchain this adapter uses. `import` rather than `dofile`: a module has
// a private environment and is instantiated once per generation, so there is no
// load-order list to keep in sync, no root-table slot to collide with, and the
// dependency graph tells a hot reload what a `lib/` edit affects.
//
// `load.nut` still loads this file with `dofile("main.nut")`. That path now
// compiles through ScriptCompiler and instantiates `import`s before running
// (`src/modules/filesystem/physfs/FileApi.cpp`), so a game entry can be the
// first script to import.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcProject } from "game:/lib/rpgc_project.nut"
import { RpgcTilemap } from "game:/lib/rpgc_tilemap.nut"
import { RpgcBattle } from "game:/lib/rpgc_battle.nut"
import { RpgcItems } from "game:/lib/rpgc_items.nut"
import { RpgcWorldState } from "game:/lib/rpgc_world_state.nut"
import { RpgcEventRunner } from "game:/lib/rpgc_event_runner.nut"
import { RpgcDialogue } from "game:/lib/rpgc_dialogue.nut"
import { RpgcQuests } from "game:/lib/rpgc_quests.nut"
import { RpgcSave } from "game:/lib/rpgc_save.nut"
import { RpgcNavigation } from "game:/lib/rpgc_navigation.nut"
import { RpgcSaveStore } from "game:/lib/rpgc_save_store.nut"

// The only copy of the roster id: the fight and the opening bag must read the
// same document, or the player owns items the party they fight with never got.
const PARTY_ID = "party.default";

persist worldMapId = "village-outskirts"
persist playerX = -1
persist playerY = -1
persist facingX = 1
persist facingY = 0
persist gold = 0
persist hudBuilt = false
persist previousKeys = {}
persist previousMouseDown = false
// The bag survives a hot reload as a JSON snapshot rather than as a live table:
// `RpgcItems.snapshot` is the same shape the engine's InventorySaveSession keeps
// for its own Bag/EquipmentSet pair, so this is the save format the game would
// ship, exercised on every reload instead of only in a test.
persist bagSnapshot = ""
persist bagOpen = false
persist worldRuntimeSnapshot = ""
persist worldInputSequence = 0
persist worldLocale = "zh-CN"

worldLayer <- null
worldPath <- null
camera <- null
atlasByGid <- {}
consumed <- {}
switches <- {}
variables <- {}
statusText <- ""
statusTimer <- 0.0
activePath <- null
pathIndex <- 0
stepClock <- 0.0
onPortal <- false
objectContract <- ""
eventDocs <- []
worldState <- null
worldSession <- null
worldQueue <- []
worldQueued <- {}
worldAcks <- []
worldDomainEvents <- []
worldDialogue <- null
worldMessage <- null
worldMessages <- {}
worldQuestDocs <- []
worldGuideQuest <- null
worldQuestError <- ""
worldRuntimeFatal <- ""
worldRenderedFrames <- 0
worldLastDiagnostics <- []
worldSaveRequested <- false
worldSaveStatus <- "尚未保存"
worldSaveLastResult <- null
worldCameraTween <- null
worldAnimation <- null
worldActors <- {}
actorFacings <- {}
pendingMapEntered <- ""
worldCapabilities <- {message=true,dialogue=true,load_map=true,camera_focus=true,camera_pan=true,
    face_actor=true,play_animation=true,move_actor=false}

// Battle state. `null` means the overworld is live; anything else means the
// fight owns the frame. None of it is `persist`: a battle is a moment, not a
// save-worthy fact, and reloading the script mid-fight should drop it.
battleFight <- null
battleExtra <- ""
battleBackground <- null
battleBackgroundPath <- ""
battleKeys <- {}

// Item state. `null` means the item documents did not load, and every caller
// checks: a missing content tree must not turn a potion into a crash.
itemsConfig <- null
itemBag <- null
itemEquip <- null

const START_MAP = "village-outskirts";
const STEP_SECONDS = 0.16;
const INTERACT_RANGE = 1;
// Packed overworld art is 128×64; isometric pitch is 256×128 (`renderSpacing`
// [2, 2]). Stretch visuals to fill the diamond. Camera zoom stays 1 — stacking
// zoom 2 on top of this scale made every tile four times native size.
const CAMERA_ZOOM = 1.0;

function say(text) {
    statusText = "" + text;
    statusTimer = 4.0;
    print("[rpgc] " + statusText + "\n");
}

function keyPressed(name) {
    local down = keyboard.isDown(name);
    local wasDown = (name in previousKeys) ? previousKeys[name] : false;
    previousKeys[name] <- down;
    return down && !wasDown;
}

function asInt(text, fallback) {
    local kind = typeof text;
    if (kind == "integer") return text;
    if (kind == "float") return text.tointeger();
    local raw = "" + text;
    local n = raw.tointeger();
    if (raw == "" + n) return n;
    return fallback;
}

function mapPath(mapId) {
    return "content/maps/" + mapId + ".json";
}

function consumedKey(mapId, name) {
    return mapId + "/" + name;
}

function loadObjectContract() {
    objectContract = eve.Filesystem().readText("data/world-object-contract.json");
    if (objectContract == "") throw "rpgc: missing data/world-object-contract.json";
}

function loadAtlasWalkRules(mapDocPath) {
    atlasByGid=RpgcNavigation.atlasRules(mapDocPath);
}

function applyNavigation(layer, pathfinder) {
    RpgcNavigation.apply(layer,pathfinder,atlasByGid);
}

function objectTile(index) {
    local wx = map.getObjectX(index);
    local wy = map.getObjectY(index);
    return {
        x = worldLayer.worldToTileX(wx, wy),
        y = worldLayer.worldToTileY(wx, wy),
        wx = wx,
        wy = wy
    };
}

function findSpawnTile() {
    local spawn = map.findObjectByName("spawn");
    if (spawn >= 0) {
        local cell = objectTile(spawn);
        if (worldPath.isWalkable(cell.x, cell.y)) return cell;
    }
    local w = worldLayer.getMapWidth();
    local h = worldLayer.getMapHeight();
    for (local y = 0; y < h; y += 1) {
        for (local x = 0; x < w; x += 1) {
            if (worldPath.isWalkable(x, y)) return { x = x, y = y, wx = 0, wy = 0 };
        }
    }
    return { x = 0, y = 0, wx = 0, wy = 0 };
}

function bindCamera() {
    if (camera == null) {
        camera = eve.Camera2D();
        camera.setZoom(CAMERA_ZOOM);
        camera.setAmbient(0.18, 0.20, 0.24);
    }
    RpgcNavigation.configureLayers(map,camera);
}

function followCamera() {
    if (worldLayer == null || camera == null) return;
    local wx = worldLayer.tileToWorldX(playerX, playerY);
    local wy = worldLayer.tileToWorldY(playerX, playerY) + worldLayer.getTileHeight() * 0.5;
    camera.setPosition(wx, wy);
}

function loadWorldMap(mapId, x, y, fx, fy, strict=false) {
    local path = mapPath(mapId);
    local raw=eve.Filesystem().readText(path);
    if (raw=="") return false;
    if (strict) {
        local target=RpgcJson.parse(raw);
        if (!target.ok || x<0 || y<0 || x>=Rpgc.get(target.value,"width",0) || y>=Rpgc.get(target.value,"height",0)) return false;
    }
    loadAtlasWalkRules(path);
    local admitted = map.loadFromFileWithObjectContract(path, objectContract);
    if (!admitted.ok) {
        print("rpgc: map rejected " + path + ": " + admitted.status.summary + "\n");
        return false;
    }
    local layer = map.getLayer(0);
    if (layer == null) return false;
    local pathfinder = map.newPathfinder(layer);
    if (pathfinder == null) return false;
    applyNavigation(layer, pathfinder);
    if (strict && !pathfinder.isWalkable(x,y)) return false;
    worldLayer = layer;
    worldPath = pathfinder;
    worldMapId = mapId;
    bindCamera();
    local spawn = findSpawnTile();
    if (x < 0 || y < 0 || !pathfinder.isWalkable(x, y)) {
        playerX = spawn.x;
        playerY = spawn.y;
    } else {
        playerX = x;
        playerY = y;
    }
    facingX = fx;
    facingY = fy;
    activePath = null;
    pathIndex = 0;
    onPortal = false;
    followCamera();
    return true;
}

function chebyshev(ax, ay, bx, by) {
    local dx = ax - bx;
    if (dx < 0) dx = -dx;
    local dy = ay - by;
    if (dy < 0) dy = -dy;
    return dx > dy ? dx : dy;
}

function nearestObject(maxRange) {
    local best = -1;
    local bestDist = maxRange + 1;
    for (local i = 0; i < map.getObjectCount(); i += 1) {
        local kind = map.getObjectType(i);
        if (kind == "spawn") continue;
        local cell = objectTile(i);
        local dist = chebyshev(playerX, playerY, cell.x, cell.y);
        if (dist <= maxRange && dist < bestDist) {
            best = i;
            bestDist = dist;
        }
    }
    return best;
}

function objectAtPlayer() {
    for (local i = 0; i < map.getObjectCount(); i += 1) {
        local cell = objectTile(i);
        if (cell.x == playerX && cell.y == playerY) return i;
    }
    return -1;
}

function loadEventDocs() {
    // Discover authored events through the same manifest index as the tools.
    // Hardcoded starter filenames made newly compiled event candidates invisible.
    local loaded = RpgcProject.loadKind("event");
    eventDocs = loaded.value;
    if (!loaded.ok) print("[rpgc] warn: event documents: " + Rpgc.summary(loaded) + "\n");
}

// Shared-rule world adapter: requests are acknowledged only after the host work.
function syncWorldPresentation() {
    if (worldState == null) return;
    gold=worldState.gold; worldMapId=worldState.mapId;
    playerX=worldState.x; playerY=worldState.y;
    facingX=worldState.facingX; facingY=worldState.facingY;
    consumed=worldState.consumed; switches=worldState.switches; variables=worldState.variables;
    if (typeof worldState.bag=="table") itemBag=worldState.bag;
}
function rememberWorldState() {
    // This is hot-reload continuity, not the complete player-save protocol.
    if (worldState != null) worldRuntimeSnapshot=RpgcJson.encodeCompact(worldState);
}
function applyWorldCommands(commands) {
    foreach (command in commands) {
        worldInputSequence+=1;
        command.commandId<-"game."+worldInputSequence;
    }
    local result=RpgcWorldState.applyBatch(worldState,commands,itemsConfig==null ? 0 : itemsConfig);
    if (!result.ok) { say("世界命令失败："+Rpgc.summary(result)); return false; }
    foreach (event in result.value.domainEvents) worldDomainEvents.append(event);
    syncWorldPresentation(); rememberWorldState();
    return true;
}
function commitPlayerPosition() {
    return applyWorldCommands([{kind="transfer",mapId=worldMapId,x=playerX,y=playerY,facingX=facingX,facingY=facingY}]);
}
function conditionHolds(condition) {
    if (condition == null) return true;
    local result=RpgcWorldState.condition(worldState,condition);
    if (!result.ok) { say("条件求值失败："+Rpgc.summary(result)); return false; }
    return result.value;
}
function worldActorPosition(actorId) {
    if (actorId=="player") return {x=playerX,y=playerY};
    for (local i=0;i<map.getObjectCount();i+=1)
        if (map.getObjectName(i)==actorId) return objectTile(i);
    return null;
}
function worldAck(request,ok,message="") {
    worldAcks.append({operationId=request.operationId,ok=ok,message=message});
    print("[rpgc-runtime] ack "+request.operationId+" "+(ok ? "ok" : "failed")+" "+message+"\n");
}
function startWorldAnimation(request) {
    local step=request.step;
    if (worldActorPosition(step.actorId)==null) { worldAck(request,false,"actor does not exist: "+step.actorId); return; }
    if (worldActors.rawin(step.actorId) && worldActors.rawget(step.actorId).operationId!="") {
        worldAck(request,false,"actor already has an unacknowledged animation"); return;
    }
    local loaded=RpgcProject.loadById("anim",step.anim);
    if (!loaded.ok) { worldAck(request,false,Rpgc.summary(loaded)); return; }
    local document=loaded.value; local selected=null;
    foreach (candidate in document.clips) if (candidate.id==step.clip) selected=candidate;
    if (selected==null) { worldAck(request,false,"animation clip does not exist"); return; }
    try {
        local imagePath=Rpgc.resolveFrom(RpgcProject.pathOf("anim",step.anim),document.image);
        local texture=gfx.newTextureFromFile(imagePath);
        if (texture==null) throw "animation texture failed to load";
        // Reuse native animation objects per actor. Repeated clips do not leak
        // hidden Sprite2D entities or registered SpriteAnim players.
        local previous=worldActors.rawin(step.actorId) ? worldActors.rawget(step.actorId) : null;
        if (previous!=null) previous.player.stop();
        local sheet=previous==null ? worldAnimation.newSpriteSheet() : previous.sheet;
        sheet.clear(); sheet.setTexture(texture);
        sheet.setGrid(document.columns,document.rows,document.frameWidth,document.frameHeight,
            Rpgc.get(document,"margin",0),Rpgc.get(document,"spacing",0),0,0);
        local clip=previous==null ? worldAnimation.newSpriteClip(step.anim+"/"+step.clip) : previous.clip;
        clip.clear(); clip.setName(step.anim+"/"+step.clip);
        foreach (frame in selected.frames) clip.addFrame(frame,1.0/selected.fps);
        // SDK SpriteClip.clear() only clears frames, not named events.
        for (local i=0;i<selected.frames.len();i+=1) clip.addEvent(i,"");
        local looping=Rpgc.get(step,"loop",Rpgc.get(selected,"loop",false));
        clip.setLoop(looping);
        foreach (event in Rpgc.get(selected,"events",[])) clip.addEvent(event.frame,event.name);
        local quad=previous==null ? gfx.newQuad(0,0,document.frameWidth,document.frameHeight) : previous.quad;
        local sprite=previous==null ? gfx.newSprite2D() : previous.sprite;
        sprite.setTexture(texture); sprite.setQuad(quad);
        sprite.setSize(document.frameWidth.tofloat()*2.0,document.frameHeight.tofloat()*2.0);
        sprite.setAnchor(0.5,1.0); sprite.setBlend("alpha"); sprite.setReceiveLight(false);
        local player=previous==null ? worldAnimation.newSpriteAnim() : previous.player;
        player.setSheet(sheet); player.bindQuad(quad); player.bindSprite(sprite); player.play(clip);
        worldActors.rawset(step.actorId,{sprite=sprite,player=player,sheet=sheet,clip=clip,quad=quad,
            request=request,operationId=request.operationId,looping=looping});
    } catch (error) { worldAck(request,false,"animation adapter: "+error); }
}
function openWorldDialogue(reference,request=null) {
    if (worldDialogue!=null) {
        if (request!=null) worldAck(request,false,"a dialogue is already active");
        return false;
    }
    local loaded=RpgcProject.loadById("dialogue",reference);
    if (!loaded.ok) {
        if (request!=null) worldAck(request,false,"dialogue definition missing: "+reference);
        else say("对话定义缺失："+reference);
        return false;
    }
    local started=RpgcDialogue.start(loaded.value,worldState,worldLocale);
    if (!started.ok) {
        if (request!=null) worldAck(request,false,Rpgc.summary(started));
        else say("对话失败："+Rpgc.summary(started));
        return false;
    }
    worldDialogue={session=started.value,request=request,view=null};
    foreach (event in RpgcDialogue.takeDomainEvents(started.value)) worldDomainEvents.append(event);
    refreshWorldDialogue(); syncWorldPresentation(); rememberWorldState();
    return true;
}
function refreshWorldDialogue() {
    if (worldDialogue==null) return;
    local viewed=RpgcDialogue.view(worldDialogue.session,worldState,worldLocale);
    if (!viewed.ok) {
        if (worldDialogue.request!=null) worldAck(worldDialogue.request,false,Rpgc.summary(viewed));
        say("对话失败："+Rpgc.summary(viewed)); worldDialogue=null; return;
    }
    worldDialogue.view=viewed.value;
    if (viewed.value.status=="completed") {
        if (worldDialogue.request!=null) worldAck(worldDialogue.request,true);
        print("[rpgc-runtime] dialogue completed "+viewed.value.dialogueId+"\n");
        worldDialogue=null;
    }
}
function worldDialogueInput(optionIndex=-1,advance=false) {
    if (worldDialogue==null) return false;
    // Submit the option ID/revision that was actually displayed. Refresh only
    // after rejection; re-indexing a stale numeric choice could select another option.
    if (worldDialogue.view==null) return false;
    local view=worldDialogue.view; local result=null;
    if (view.kind=="line" && advance) result=RpgcDialogue.advance(worldDialogue.session,worldState,view.revision);
    if (view.kind=="choice" && optionIndex>=0 && optionIndex<view.options.len())
        result=RpgcDialogue.choose(worldDialogue.session,worldState,view.options[optionIndex].id,view.revision);
    if (result!=null) {
        if (!result.ok) say("对话操作失败："+Rpgc.summary(result));
        else foreach (event in RpgcDialogue.takeDomainEvents(worldDialogue.session)) worldDomainEvents.append(event);
        syncWorldPresentation(); rememberWorldState(); refreshWorldDialogue();
    }
    return result!=null && result.ok;
}
function handleWorldRequest(request) {
    print("[rpgc-runtime] request "+request.operationId+" "+request.kind+"\n");
    local step=request.step;
    if (request.kind=="message") {
        if (!worldMessages.rawin(step.reference)) { worldAck(request,false,"message text is missing: "+step.reference); return; }
        if (worldMessage!=null || worldDialogue!=null) { worldAck(request,false,"message/dialogue channel is busy"); return; }
        worldMessage={request=request,text=worldMessages.rawget(step.reference)};
        say(worldMessage.text);
    } else if (request.kind=="dialogue") {
        if (worldMessage!=null) worldAck(request,false,"message/dialogue channel is busy");
        else openWorldDialogue(step.reference,request);
    } else if (request.kind=="load_map") {
        local oldMap=worldState.mapId; local oldX=worldState.x; local oldY=worldState.y;
        local oldFX=worldState.facingX; local oldFY=worldState.facingY;
        local loaded=false;
        if (step.x==asInt(step.x,-1) && step.y==asInt(step.y,-1))
            loaded=loadWorldMap(step.mapId,asInt(step.x,-1),asInt(step.y,-1),oldFX,oldFY,true);
        if (loaded) {
            worldAck(request,true);
            pendingMapEntered=step.mapId;
        } else {
            local restored=loadWorldMap(oldMap,asInt(oldX,-1),asInt(oldY,-1),oldFX,oldFY,true);
            if (!restored) worldRuntimeFatal="地图转移失败且旧地图无法恢复；请修复内容后重新加载。";
            worldAck(request,false,restored ? "invalid map/landing cell; previous map restored" : "map transfer and rollback both failed");
        }
    } else if (request.kind=="camera_focus" || request.kind=="camera_pan") {
        if (camera==null || worldCameraTween!=null) { worldAck(request,false,"camera unavailable or already moving"); return; }
        worldCameraTween={request=request,elapsed=0.0,duration=Rpgc.get(step,"duration",0.0),
            fromX=camera.getX(),fromY=camera.getY(),fromZoom=camera.getZoom(),
            toX=step.x,toY=step.y,toZoom=Rpgc.get(step,"zoom",camera.getZoom())};
    } else if (request.kind=="face_actor") {
        if (worldActorPosition(step.actorId)==null) { worldAck(request,false,"actor not present: "+step.actorId); return; }
        actorFacings.rawset(step.actorId,{x=step.facingX,y=step.facingY});
        if (worldActors.rawin(step.actorId)) worldActors.rawget(step.actorId).sprite.setFlip(step.facingX<0,false);
        worldAck(request,true);
    } else if (request.kind=="play_animation") startWorldAnimation(request);
    else worldAck(request,false,"runtime.capability-missing: "+request.kind);
}
function updateWorldPresentation(dt) {
    if (worldCameraTween!=null) {
        local tween=worldCameraTween;
        tween.elapsed+=dt;
        local amount=tween.duration>0 ? tween.elapsed/tween.duration : 1.0;
        if (amount>1.0) amount=1.0;
        camera.setPosition(tween.fromX+(tween.toX-tween.fromX)*amount,tween.fromY+(tween.toY-tween.fromY)*amount);
        camera.setZoom(tween.fromZoom+(tween.toZoom-tween.fromZoom)*amount);
        if (amount>=1.0) { worldAck(tween.request,true); worldCameraTween=null; }
    }
    foreach (actorId,actor in worldActors) {
        actor.player.update(dt);
        local event=actor.player.consumeEvent();
        if (event!="") print("[rpgc-runtime] animation-event "+actorId+" "+event+"\n");
        if (actor.operationId!="" && (actor.looping || actor.player.isFinished())) {
            worldAck(actor.request,true); actor.operationId="";
        }
    }
}
function runEventDoc(doc) {
    if ((!Rpgc.get(doc,"repeatable",false) && worldState.completedEvents.rawin(doc.id)) || worldQueued.rawin(doc.id)) return false;
    if (worldSession!=null && worldSession.eventId==doc.id) return false;
    worldQueued.rawset(doc.id,true); worldQueue.append(RpgcWorldState.copyValue(doc));
    return true;
}
function dispatchWorldTrigger(kind,extra="",mapId="") {
    if (mapId=="") mapId=worldMapId;
    local matches=[];
    foreach (doc in eventDocs) {
        local trigger=Rpgc.get(doc,"trigger",{});
        if (Rpgc.get(trigger,"kind","")!=kind) continue;
        if (trigger.rawin("mapId") && trigger.mapId!=mapId) continue;
        if (kind=="portal_entered" && Rpgc.get(trigger,"targetMap","")!=extra) continue;
        if (kind=="object_interacted" && Rpgc.get(trigger,"objectName","")!=extra) continue;
        if (kind=="quest_completed" && Rpgc.get(trigger,"questId","")!=extra) continue;
        matches.append(doc);
    }
    matches.sort(function(a,b) { return a.id<b.id ? -1 : (a.id>b.id ? 1 : 0); });
    local count=0;
    foreach (doc in matches) if (runEventDoc(doc)) count+=1;
    return count;
}
function cancelWorldEvent() {
    // A native map may already have loaded while its transfer ack is pending.
    // Cancelling must restore that uncommitted map, not merely discard the ack.
    if (pendingMapEntered!="") {
        local restored=loadWorldMap(worldState.mapId,asInt(worldState.x,-1),asInt(worldState.y,-1),
            worldState.facingX,worldState.facingY,true);
        if (!restored) worldRuntimeFatal="取消地图转移后无法恢复旧地图；请重新加载。";
        pendingMapEntered="";
    }
    if (worldDialogue!=null) { RpgcDialogue.cancel(worldDialogue.session); worldDialogue=null; }
    worldMessage=null; worldCameraTween=null;
    if (worldSession!=null) RpgcEventRunner.cancel(worldSession,worldState);
    foreach (actorId,actor in worldActors) {
        if (actor.operationId!="") { actor.player.stop(); actor.operationId=""; }
    }
    worldSession=null; worldAcks=[]; worldQueue=[]; worldQueued={};
    rememberWorldState(); say("演出已取消；已提交的动作保留。");
}
function updateWorldEvents(dt) {
    updateWorldPresentation(dt);
    if (worldSession==null && worldQueue.len()>0) {
        local doc=worldQueue.remove(0); worldQueued.rawdelete(doc.id);
        local made=RpgcEventRunner.newSession(doc,worldState,worldCapabilities);
        if (!made.ok) { worldLastDiagnostics=made.diagnostics; say("事件无法开始："+Rpgc.summary(made)); return; }
        worldLastDiagnostics=[];
        worldSession=made.value; activePath=null; bagOpen=false;
    }
    if (worldSession==null) return;
    local acks=worldAcks; worldAcks=[];
    local result=RpgcEventRunner.tick(worldSession,worldState,dt,acks);
    if (typeof result.value=="table") foreach (event in result.value.domainEvents) worldDomainEvents.append(event);
    syncWorldPresentation(); rememberWorldState();
    if (!result.ok) {
        worldLastDiagnostics=result.diagnostics;
        say("事件失败："+Rpgc.summary(result));
        worldCameraTween=null; worldMessage=null; worldDialogue=null;
        foreach (actorId,actor in worldActors) if (actor.operationId!="") { actor.player.stop(); actor.operationId=""; }
        worldSession=null; worldAcks=[]; pendingMapEntered=""; return;
    }
    foreach (request in result.value.requests) {
        try { handleWorldRequest(request); }
        catch (error) { worldAck(request,false,"host adapter failed: "+error); }
    }
    if (pendingMapEntered!="" && worldState.mapId==pendingMapEntered) {
        local entered=pendingMapEntered; pendingMapEntered="";
        dispatchWorldTrigger("map_entered","",entered);
    }
    if (result.value.status=="completed") {
        print("[rpgc-runtime] event completed "+worldSession.eventId+"\n");
        worldSession=null; worldAcks=[];
    }
}
// Read-only game diagnostics consumed by the real-host smoke tool and MCP.
function worldRuntimeReport() {
    local options=[];
    if (worldDialogue!=null && worldDialogue.view!=null) options=worldDialogue.view.options;
    local quest=worldGuideQuest!=null && worldState.quests.rawin(worldGuideQuest.id) ? worldState.quests.rawget(worldGuideQuest.id).status : "inactive";
    local nativeObjects=[];
    for (local i=0;i<map.getObjectCount();i+=1) nativeObjects.append(map.getObjectName(i));
    nativeObjects.sort();
    local actors=[];
    foreach (id,actor in worldActors) actors.append({id=id,frame=actor.player.getSheetFrame(),playing=actor.player.isPlaying(),pending=actor.operationId});
    return RpgcJson.encodeCompact({mapId=worldMapId,x=playerX,y=playerY,gold=worldState.gold,
        potionCount=itemBag==null ? 0 : RpgcItems.countOf(itemBag,"potion.heal"),questStatus=quest,
        consumed=worldState.consumed,completedEvents=worldState.completedEvents,
        currentEvent=worldSession==null ? "" : worldSession.eventId,busy=worldBusy(),
        dialogueKind=worldDialogue==null ? "" : worldDialogue.view.kind,
        dialogueText=worldDialogue==null ? "" : worldDialogue.view.text,options=options,
        message=worldMessage==null ? "" : worldMessage.text,actors=actors,renderedFrames=worldRenderedFrames,
        cameraX=camera==null ? 0 : camera.getX(),cameraY=camera==null ? 0 : camera.getY(),
        clock=worldState.clock,statusText=statusText,fatal=worldRuntimeFatal,questError=worldQuestError,
        saveRequested=worldSaveRequested,saveStatus=worldSaveStatus,saveDirectory=RpgcSaveStore.directory,saveResult=worldSaveLastResult,
        lastDiagnostics=worldLastDiagnostics,nativeObjects=nativeObjects,
        nativeOriginX=worldLayer==null ? 0 : worldLayer.tileToWorldX(0,0),
        nativeOriginY=worldLayer==null ? 0 : worldLayer.tileToWorldY(0,0)});
}
function worldBusy() { return worldSession!=null || worldQueue.len()>0 || worldDialogue!=null || worldMessage!=null; }

function enterPortal(index) {
    local targetMap = map.getObjectProperty(index, "targetMap", "");
    if (dispatchWorldTrigger("portal_entered",targetMap)>0) return;
    local loaded=loadWorldMap(targetMap,
                 asInt(map.getObjectProperty(index, "targetX", "0"), 0),
                 asInt(map.getObjectProperty(index, "targetY", "0"), 0),
                 asInt(map.getObjectProperty(index, "facingX", "1"), 1),
                 asInt(map.getObjectProperty(index, "facingY", "0"), 0));
    if (loaded) { commitPlayerPosition(); dispatchWorldTrigger("map_entered"); say("进入 " + targetMap); }
    else say("地图载入失败："+targetMap);
}

function interactObject(index) {
    if (index < 0) {
        say("附近没有可互动的对象");
        return;
    }
    local kind = map.getObjectType(index);
    local name = map.getObjectName(index);
    if (kind == "portal") {
        enterPortal(index);
        return;
    }
    if (kind == "npc") {
        if (dispatchWorldTrigger("object_interacted",name)>0) return;
        openWorldDialogue(map.getObjectProperty(index,"dialogue",""));
        return;
    }
    if (kind == "chest") {
        local key = consumedKey(worldMapId, name);
        if (key in consumed) {
            say("箱子是空的");
            return;
        }
        local amount = asInt(map.getObjectProperty(index, "gold", "0"), 0);
        local itemId=map.getObjectProperty(index,"itemId","");
        local rewards=[];
        if (itemId!="") rewards.append({kind="give_item",itemId=itemId,quantity=1});
        rewards.append({kind="set_variable",name="gold",op="add",value=amount});
        rewards.append({kind="consume_object",mapId=worldMapId,objectName=name});
        if (!applyWorldCommands(rewards)) return;
        saveBag();
        say("获得 " + (itemId=="" ? "" : itemId+" 和 ") + amount + " 金币");
        return;
    }
    say(name);
}

function tryMove(dx, dy) {
    if (dx == 0 && dy == 0) return;
    local nx = playerX + dx;
    local ny = playerY + dy;
    if (!worldPath.isWalkable(nx, ny)) {
        say("无法通行");
        return;
    }
    playerX = nx;
    playerY = ny;
    facingX = dx;
    facingY = dy;
    activePath = null;
    commitPlayerPosition();
    followCamera();
}

function requestPath(tx, ty) {
    if (!worldPath.isWalkable(tx, ty)) {
        say("目标无法通行");
        return;
    }
    activePath = worldPath.findPath(playerX, playerY, tx, ty);
    pathIndex = (activePath != null && activePath.getLength() > 1) ? 1 : 0;
    stepClock = 0.0;
    if (activePath == null || activePath.getLength() == 0) say("没有路线");
}

function refreshHud() {
    if (!hudBuilt) return;
    ui.select("hud");
    if (worldDialogue!=null) refreshWorldDialogue();
    ui.setText("dialogue",worldDialoguePanel());
    if (battleFight != null) {
        ui.setText("area", battleHeader());
        ui.setText("help", battleHelp());
        ui.setText("battle", battleRoster());
        ui.setText("items", "");
        ui.setText("status", statusText);
        return;
    }
    if (bagOpen) {
        ui.setText("area", bagSummary());
        ui.setText("help", "1..9 装备 / 查看 · I 关闭背包");
        ui.setText("battle", "");
        ui.setText("items", bagPanelText() + "\n装备：" + equipSummary());
        ui.setText("status", statusText);
        return;
    }
    ui.setText("area", worldMapId + "  (" + playerX + "," + playerY + ")  金币 " + gold);
    ui.setText("help",worldBusy() ? "演出进行中 · 空格 / Enter 继续 · 1..9 选择 · Esc 取消" : "WASD 移动 · E 互动 · B 战斗 · I 背包 · T 向导任务");
    ui.setText("battle", worldQuestSummary());
    ui.setText("items", "");
    ui.setText("status", statusText);
}

// --------------------------------------------------------------------- items
//
// The runtime half of docs/08-items-and-equipment.md. The documents stay the
// source of truth and `RpgcItems` owns the arithmetic; this file owns the screen,
// the keyboard, and the three moments where a bag changes: start-up, loot, and
// a player using or wearing something.
//
// Nothing here calls the engine's inventory module, because this build does not
// bind it (`cmake/module_manifest/core_foundation.cmake:105` declares `inventory`
// with no SLOT, so `eve.Inventory` is not on the `eve` table at all --
// tools/modules_check.nut asserts that). docs/08 §7 used to show
// `eve.Inventory().registerItemsFromJson(...)`; that call cannot run here.

function setupItems() {
    local loaded = RpgcItems.loadProject();
    if (!loaded.ok) {
        itemsConfig = null;
        itemBag = null;
        itemEquip = null;
        print("[rpgc] warn: item documents did not load: " + Rpgc.summary(loaded) + "\n");
        return false;
    }
    itemsConfig = loaded.value;
    itemEquip = RpgcItems.newEquipmentSet(itemsConfig, "party");

    if (bagSnapshot != "") {
        local restored = RpgcItems.restore(bagSnapshot, itemsConfig);
        if (restored.ok) {
            itemBag = restored.value.bag;
            itemEquip = restored.value.equipment;
            return true;
        }
        // A snapshot that no longer matches the content tree is refused rather
        // than half-applied (`RpgcItems.restore` never leaves a partial bag), so
        // the fallback is a fresh bag and a loud line, not a silent reset.
        print("[rpgc] warn: bag snapshot rejected: " + Rpgc.summary(restored) + "\n");
    }

    itemBag = RpgcItems.newBag(RpgcItems.defaultBagSlots, "party");
    local party = RpgcProject.loadById("party", PARTY_ID);
    if (party.ok) {
        foreach (row in Rpgc.get(party.value, "startingItems", [])) {
            local itemId = Rpgc.asString(Rpgc.get(row, "itemId", ""));
            local count = Rpgc.asInt(Rpgc.get(row, "count", 0));
            if (itemId == "" || count <= 0) continue;
            local placed = RpgcItems.add(itemBag, itemsConfig, itemId, count);
            if (!placed.ok || placed.value.added < count) {
                // The opening kit does not fit the bag, which is a content
                // mistake the gate cannot see (it has no slot count). Reported
                // instead of silently dropping the difference.
                print("[rpgc] warn: starting item '" + itemId + "' only partly placed\n");
            }
        }
    }
    saveBag();
    return true;
}

// Persist the bag as the snapshot the next start-up reads back. Called after
// every mutation, so a hot reload can never lose a potion the player just used.
function saveBag() {
    if (itemBag == null || itemEquip == null) return;
    bagSnapshot = RpgcJson.encodeCompact(RpgcItems.snapshot(itemBag, itemEquip));
    if (worldState!=null) { worldState.bag=itemBag; rememberWorldState(); }
}

function bagRows() {
    if (itemBag == null || itemsConfig == null) return [];
    return RpgcItems.entries(itemBag, itemsConfig);
}

function bagSummary() {
    if (itemBag == null) return "物品系统不可用";
    return "背包 " + RpgcItems.usedSlots(itemBag) + "/" + itemBag.slots.len() + " 格 · 重 "
        + RpgcItems.usedWeight(itemBag, itemsConfig) + " · 金币 " + gold;
}

function equipSummary() {
    if (itemEquip == null) return "";
    local parts = [];
    foreach (slot in itemEquip.order) {
        local itemId = RpgcItems.equipped(itemEquip, slot);
        if (itemId != "") parts.append(slot + "=" + itemId);
    }
    return parts.len() == 0 ? "未装备" : Rpgc.joinList(parts, " ");
}

function bagPanelText() {
    local rows = bagRows();
    if (rows.len() == 0) return "背包是空的。";
    local lines = [];
    for (local i = 0; i < rows.len() && i < 9; i += 1) {
        local row = rows[i];
        local suffix = "";
        if (row.equipment) {
            suffix = "  [装备 " + RpgcItems.slotOf(RpgcItems.definitionOf(itemsConfig, row.itemId)) + "]";
        } else if (row.usable) {
            suffix = "  [战斗中用]";
        }
        lines.append("" + (i + 1) + "  " + row.displayName + "×" + row.quantity + suffix);
    }
    if (rows.len() > 9) lines.append("…还有 " + (rows.len() - 9) + " 行");
    return Rpgc.joinList(lines, "\n");
}

// The overworld bag does exactly two things, and refusing the third is the
// design: a `use.effects` list is applied by `RpgcBattle.applyEffect`, which
// needs a fight. Drinking a potion in a town would consume it and do nothing,
// so the panel says so instead.
function bagAct(index) {
    local rows = bagRows();
    if (index < 0 || index >= rows.len()) return false;
    local row = rows[index];
    local def = RpgcItems.definitionOf(itemsConfig, row.itemId);
    if (def != 0 && RpgcItems.isEquipment(def)) {
        local equipped = RpgcItems.equip(itemBag, itemEquip, itemsConfig, row.itemId);
        if (!equipped.ok) {
            say("装备不了：" + Rpgc.summary(equipped));
            return false;
        }
        saveBag();
        say("装备 " + row.displayName + " → " + equipped.value.slot
            + (equipped.value.replaced == "" ? "" : "（换下 " + equipped.value.replaced + "）"));
        return true;
    }
    if (row.usable) {
        say("「" + row.displayName + "」要在战斗里用（开战后按对应数字键）。");
        return false;
    }
    say("「" + row.displayName + "」现在用不了。");
    return false;
}

// ------------------------------------------------------------------- battle
//
// The runtime half of docs/10-battle-scene.md and docs/11-battle-system.md: the
// documents stay the source of truth and everything here is a projection of
// them. `RpgcBattle` owns the rules and the state machine; this file owns the
// screen, the keyboard and the two lines of glue that start and end a fight.
//
// The encounter is chosen by MAP, not by a map object: this workflow deliberately
// models no "step on it and fight" object type (docs/09 §7), and every map has
// exactly one encounter gated against it (`systems.encounter-without-battle`).
// Pressing B is therefore the whole of the trigger -- an explicit gesture rather
// than an invisible one.

function encounterForMap(mapId) {
    foreach (id in RpgcProject.idsOf("encounter")) {
        local read = RpgcProject.loadById("encounter", id);
        if (!read.ok) continue;
        if (Rpgc.asString(Rpgc.get(read.value, "map", "")) == mapId) return id;
    }
    return "";
}

function startBattle() {
    local encounterId = encounterForMap(worldMapId);
    if (encounterId == "") {
        say("这块地方没有遭遇。");
        return;
    }
    local config = RpgcBattle.loadProject(PARTY_ID, encounterId, "");
    if (!config.ok) {
        say("战斗无法开始：" + Rpgc.summary(config));
        return;
    }
    local fight = RpgcBattle.newFight(config.value);
    if (!fight.ok) {
        say("战斗无法开始：" + Rpgc.summary(fight));
        return;
    }
    battleFight = fight.value;
    battleExtra = "";
    battleKeys = {};
    loadBattleBackground();
    statusText = "";
    statusTimer = 0.0;
    print("[rpgc] battle " + encounterId + " on " + worldMapId + "\n");
    refreshHud();
}

function loadBattleBackground() {
    local declared = Rpgc.asString(Rpgc.get(battleFight.battle, "background", ""));
    battleBackground = null;
    battleBackgroundPath = "";
    if (declared == "") return;
    local path = "content/battles/" + Rpgc.normalizePath(declared);
    battleBackgroundPath = path;
    battleBackground = gfx.newTextureFromFile(path);
    if (battleBackground == null) {
        // `newTextureFromFile` swallows a missing file, so a scene would simply
        // stop drawing its backdrop with nothing said anywhere. The editor
        // learned this the same way (docs/10 §6.4).
        print("[rpgc] warn: battle backdrop '" + path + "' failed to load\n");
    }
}

// The ring has one button per `ui.commandRing.buttons` entry and the keyboard
// has nine digits, so the usable command list is capped by whichever is smaller.
// `RpgcSystems.battleUiDiagnostics` caps the ring at `maxBattlePartyBars` keys,
// and the cap is applied HERE rather than to the documents because what fits is
// a property of this adapter's screen, not of the content.
function battleCommandLimit() {
    if (battleFight == null) return 9;
    local ring = Rpgc.get(Rpgc.get(battleFight.battle, "ui", 0), "commandRing", 0);
    if (typeof ring != "table") return 9;
    local buttons = Rpgc.get(ring, "buttons", []).len();
    if (buttons <= 0) return 9;
    return buttons < 9 ? buttons : 9;
}

function battleCommandList() {
    if (battleFight == null) return [];
    local unit = RpgcBattle.unitOf(battleFight, battleFight.pending);
    if (unit == 0) return [];
    local out = [];
    foreach (entry in RpgcBattle.commandsFor(battleFight, unit)) {
        if (entry.id == "command.defend") {
            out.append(entry);
            continue;
        }
        // Only what can be used now gets a key: a refused order still spends the
        // unit's turn in `RpgcBattle.performSkill`'s contract, and a button that
        // silently costs a turn is worse than no button.
        if (entry.ready && entry.affordable) out.append(entry);
    }
    // Consumables come after the moves: a skill is the primary action and an
    // item is the exception. `RpgcItems.battleCommands` carries the effects, so
    // the resolver below never reads an item document.
    if (itemBag != null && itemsConfig != null) {
        foreach (entry in RpgcItems.battleCommands(itemBag, itemsConfig)) out.append(entry);
    }
    local limit = battleCommandLimit();
    if (out.len() > limit) {
        local kept = [];
        for (local i = 0; i < limit; i += 1) kept.append(out[i]);
        return kept;
    }
    return out;
}

// The player picks the move; the target follows the move's own target type, so
// a heal never tries to land on an enemy and a self buff needs no target at all.
function battleDefaultTarget(unit, targetType) {
    if (targetType == "self") return unit.id;
    if (targetType == "allySingle" || targetType == "allyAll") {
        local best = 0;
        local bestFraction = 2.0;
        foreach (candidate in RpgcBattle.livingUnits(battleFight, unit.side)) {
            local fraction = candidate.maxHp > 0.0 ? candidate.hp / candidate.maxHp : 1.0;
            if (fraction < bestFraction) {
                best = candidate;
                bestFraction = fraction;
            }
        }
        return best == 0 ? "" : best.id;
    }
    return RpgcBattle.pickTarget(battleFight, unit);
}

function battleAct(index) {
    local unit = RpgcBattle.unitOf(battleFight, battleFight.pending);
    if (unit == 0) return false;
    local commands = battleCommandList();
    if (index < 0 || index >= commands.len()) return false;
    local chosen = commands[index];
    if (chosen.id == "command.defend") {
        RpgcBattle.submitCommand(battleFight, { skill = "command.defend", target = "" });
        return true;
    }
    // An item order is submitted BEFORE the item leaves the bag: the resolver
    // refuses an illegal target without spending anything, and a bag mutation
    // first would make a refused order cost a potion. The order carries its own
    // effects, so `RpgcBattle` never has to know what an item is.
    if (chosen.id.find("command.item:") == 0) {
        local order = {};
        order.itemId <- chosen.itemId;
        order.label <- chosen.label;
        order.targetType <- chosen.targetType;
        order.target <- battleDefaultTarget(unit, chosen.targetType);
        order.effects <- chosen.effects;
        local done = RpgcBattle.submitItemCommand(battleFight, order);
        if (!done.ok) {
            battleExtra = Rpgc.summary(done);
            return false;
        }
        local used = RpgcItems.use(itemBag, itemsConfig, chosen.itemId);
        if (used.ok) {
            saveBag();
            battleExtra = used.value.displayName + " → " + Rpgc.joinList(used.value.effects, "、");
        }
        return true;
    }
    local target = battleDefaultTarget(unit, chosen.targetType);
    RpgcBattle.submitCommand(battleFight, { skill = chosen.id, target = target });
    return true;
}

function drainBattleEvents() {
    foreach (event in RpgcBattle.takeEvents(battleFight)) {
        if (event.kind == "broken") {
            battleExtra = "破绽被击穿！";
        }
    }
}

function updateBattle(dt) {
    if (battleFight == null) return;
    drainBattleEvents();

    if (battleFight.outcome != "") {
        finishBattle();
        return;
    }
    local commands = battleCommandList();
    for (local i = 0; i < commands.len() && i < 9; i += 1) {
        local key = "" + (i + 1);
        if (!keyPressed(key)) continue;
        battleExtra = "";
        battleAct(i);
        drainBattleEvents();
        break;
    }
    if (keyPressed("q") || keyPressed("Q")) {
        RpgcBattle.runToEnd(battleFight, 400);
        drainBattleEvents();
    }
    if (battleFight.outcome != "") finishBattle();
}

// Rewards are applied to the overworld here and only here: the fight reports, the
// game decides (docs/11 §6). XP has nowhere to go yet -- this workflow models no
// level curve -- so it is reported rather than spent, which is the honest shape.
function finishBattle() {
    local settled = RpgcBattle.settlement(battleFight);
    local line = "";
    if (settled.outcome == "victory") {
        applyWorldCommands([{kind="set_variable",name="gold",op="add",value=settled.gold}]);
        line = "胜利（" + settled.rounds + " 回合） +" + settled.gold + " 金币";
        // The drops go INTO the bag here. Before the bag existed this line
        // printed the ids and the items evaporated -- the settlement reported
        // them, nothing held them, and the screen made it look like a reward.
        if (itemBag != null && itemsConfig != null) {
            local placed = RpgcItems.applyLoot(itemBag, itemsConfig, settled.loot);
            foreach (entry in placed.value.added) {
                line += "、" + entry.itemId + "×" + entry.count;
            }
            foreach (entry in placed.value.lost) {
                // `addItem` returns a partial count and says nothing, so a full
                // bag would otherwise read as a full reward.
                line += "（" + entry.itemId + "×" + entry.count + " 放不下）";
            }
            saveBag();
        } else {
            foreach (entry in settled.loot) line += "、" + entry.itemId + "×" + entry.count;
        }
    } else if (settled.outcome == "defeat") {
        line = "我方全灭。退回 " + worldMapId + "。";
    } else {
        line = "战斗以「" + settled.outcome + "」结束。";
    }
    print("[rpgc] battle outcome=" + settled.outcome + " rounds=" + settled.rounds
        + " gold=" + settled.gold + "\n");
    battleFight = null;
    battleExtra = "";
    battleBackground = null;
    battleBackgroundPath = "";
    say(line);
    refreshHud();
}

function battleHeader() {
    if (battleFight == null) return "";
    local encounter = battleFight.encounter;
    return "战斗 · " + Rpgc.asString(Rpgc.get(encounter, "displayName", "遭遇"))
        + " · 第 " + battleFight.round + " 回合"
        + (battleExtra == "" ? "" : "   " + battleExtra);
}

function battleHelp() {
    if (battleFight == null) return "";
    local commands = battleCommandList();
    if (commands.len() == 0) return "……";
    local parts = [];
    for (local i = 0; i < commands.len() && i < 9; i += 1) {
        parts.append((i + 1) + "=" + commands[i].label);
    }
    return Rpgc.joinList(parts, "  ") + "   Q=自动打完";
}

function battleRoster() {
    if (battleFight == null) return "";
    local lines = [];
    foreach (unit in battleFight.units) {
        if (unit.side != RpgcBattle.allySide) continue;
        lines.append(unit.displayName + " " + unit.hp.tointeger() + "/"
            + unit.maxHp.tointeger() + " 破绽 " + unit.breakValue + "/" + unit.breakMax
            + (unit.alive ? "" : " [倒]"));
    }
    foreach (unit in battleFight.units) {
        if (unit.side != RpgcBattle.enemySide) continue;
        lines.append(unit.displayName + " " + unit.hp.tointeger() + "/"
            + unit.maxHp.tointeger() + (unit.alive ? "" : (unit.fled ? " [逃]" : " [倒]")));
    }
    return Rpgc.joinList(lines, "\n");
}

// ---------------------------------------------------------------- battle draw

function battleFit() {
    return RpgcBattle.fitToViewport(battleFight.battle,
        gfx.getWidth().tofloat(), gfx.getHeight().tofloat());
}

// Text is optional furniture. `Graphics::drawText` throws on a null font
// (`src/modules/graphics/Graphics.cpp:1735`), and the font belongs to whoever
// loaded one, so the battle screen asks and draws without labels when nobody
// provided it: a HUD that dies because a font is missing is worse than a HUD
// without names.
function hudFont() {
    local font = null;
    try { font = gfx.getFont(); } catch (e) { font = null; }
    return font;
}

function hudText(text, x, y, r, g, b, scale) {
    local font = hudFont();
    if (font == null) return;
    gfx.drawText(font, "" + text, x, y, r, g, b, 1.0, scale);
}

// A 3x5 bitmap face, one row per entry, bit 2 = leftmost column. It exists
// because this workflow ships no font file and the engine's script text path
// needs one (`gfx.getFont()` is null here, and the default charset is ASCII),
// so `hudText` draws nothing and the HUD would show bars without numbers.
// Digits and a slash are all the bars need; a game that installs a real font
// gets names through `hudText` on top of these.
hudGlyphs <- {
    ["0"] = [0x7, 0x5, 0x5, 0x5, 0x7],
    ["1"] = [0x2, 0x6, 0x2, 0x2, 0x7],
    ["2"] = [0x7, 0x1, 0x7, 0x4, 0x7],
    ["3"] = [0x7, 0x1, 0x7, 0x1, 0x7],
    ["4"] = [0x5, 0x5, 0x7, 0x1, 0x1],
    ["5"] = [0x7, 0x4, 0x7, 0x1, 0x7],
    ["6"] = [0x7, 0x4, 0x7, 0x5, 0x7],
    ["7"] = [0x7, 0x1, 0x1, 0x1, 0x1],
    ["8"] = [0x7, 0x5, 0x7, 0x5, 0x7],
    ["9"] = [0x7, 0x5, 0x7, 0x1, 0x7],
    ["/"] = [0x1, 0x1, 0x2, 0x4, 0x4],
    [" "] = [0x0, 0x0, 0x0, 0x0, 0x0]
};

function hudGlyphWidth(height) {
    local pixel = height / 5.0;
    if (pixel < 1.0) pixel = 1.0;
    return pixel;
}

function hudDigits(text, x, y, height, r, g, b, a) {
    local pixel = hudGlyphWidth(height);
    local cursor = x;
    local raw = "" + text;
    for (local i = 0; i < raw.len(); i += 1) {
        local ch = raw.slice(i, i + 1);
        local rows = hudGlyphs.rawin(ch) ? hudGlyphs.rawget(ch) : hudGlyphs[" "];
        for (local row = 0; row < 5; row += 1) {
            for (local col = 0; col < 3; col += 1) {
                if (rows[row] & (4 >> col)) {
                    gfx.drawSolidRect(cursor + col * pixel, y + row * pixel,
                        pixel, pixel, r, g, b, a);
                }
            }
        }
        cursor += 4.0 * pixel;
    }
    return cursor - x;
}

// One readout, two renderers: the game's font when it installed one, the rect
// face otherwise. The caller passes the row's height, not a scale, because the
// two renderers scale differently.
function hudReadout(text, x, y, height, r, g, b) {
    local font = hudFont();
    if (font != null) {
        gfx.drawText(font, "" + text, x, y, r, g, b, 1.0, height / 12.0);
        return;
    }
    hudDigits(text, x, y, height, r, g, b, 1.0);
}

// Four bars, because the script surface has no outline mode. This is also the
// shape that exposed the depth bug: an inner rect drawn after an outer one was
// rejected by the pipeline's default depth test and vanished, so the whole HUD
// painted as one flat plate (docs/11 §5, §9).
function hudFrame(x, y, w, h, thickness, r, g, b, a) {
    if (thickness <= 0.0 || w <= 0.0 || h <= 0.0) return;
    gfx.drawSolidRect(x, y, w, thickness, r, g, b, a);
    gfx.drawSolidRect(x, y + h - thickness, w, thickness, r, g, b, a);
    gfx.drawSolidRect(x, y, thickness, h, r, g, b, a);
    gfx.drawSolidRect(x + w - thickness, y, thickness, h, r, g, b, a);
}

// `hue` arrives in [0,1) so `sector` is in [0,6): truncating is flooring, and
// this build's script environment exposes no `floor` at all.
function hudHsv(hue, saturation, value) {
    local sector = hue * 6.0;
    local index = sector.tointeger();
    local f = sector - index;
    local p = value * (1.0 - saturation);
    local q = value * (1.0 - saturation * f);
    local t = value * (1.0 - saturation * (1.0 - f));
    if (index == 0) return [value, t, p];
    if (index == 1) return [q, value, p];
    if (index == 2) return [p, value, t];
    if (index == 3) return [p, q, value];
    if (index == 4) return [t, p, value];
    return [value, p, q];
}

// An element's colour is its INDEX in `rules.elements`, not a table here: a
// sixth element added to the rule document gets a colour without touching this
// file. The rule document stays the only authority on what the elements are.
function hudElementColour(element) {
    local elements = Rpgc.get(battleFight.rules, "elements", []);
    local count = elements.len();
    for (local i = 0; i < count; i += 1) {
        if (Rpgc.asString(elements[i]) == Rpgc.asString(element))
            return hudHsv(i.tofloat() / count.tofloat(), 0.55, 0.90);
    }
    return [0.42, 0.45, 0.54];
}

function unitAtSlot(side, slot) {
    foreach (unit in battleFight.units) {
        if (unit.side == side && unit.slot == slot) return unit;
    }
    return 0;
}

// The two numbers a character HUD exists to show: how much is left of a pool,
// and how much of it there is. A pool the rule document does not declare has no
// maximum, so it reads 0/0 rather than a plausible-looking lie -- the bar's id
// is checked against /resources by `systems.battle-ui-bar-unregistered`.
function hudPoolCurrent(unit, id) {
    if (id == "hp") return unit.hp;
    return unit.resources.rawin(id) ? unit.resources.rawget(id) : 0.0;
}

function hudPoolMaximum(unit, id) {
    if (id == "hp") return unit.maxHp;
    return unit.resourceMax.rawin(id) ? unit.resourceMax.rawget(id) : 0.0;
}

function drawBattleUnit(unit, fit) {
    local placed = 0;
    foreach (entry in RpgcBattle.placeOnScene(battleFight)) {
        if (entry.unit == unit.id) placed = entry;
    }
    if (placed == 0) return;
    local x = RpgcBattle.toScreenX(fit, placed.x);
    local y = RpgcBattle.toScreenY(fit, placed.y);
    local w = 72.0 * fit.scale;
    local h = 96.0 * fit.scale;

    local r = 0.78;
    local g = 0.30;
    local b = 0.26;
    if (unit.side == RpgcBattle.allySide) {
        r = 0.28;
        g = 0.48;
        b = 0.82;
    }
    if (!unit.alive) {
        r = 0.22;
        g = 0.22;
        b = 0.24;
    }
    if (battleFight.pending == unit.id) {
        gfx.drawSolidRect(x - w * 0.5 - 4.0, y - h - 4.0, w + 8.0, h + 8.0, 1.0, 0.92, 0.35, 1.0);
    }
    gfx.drawSolidRect(x - w * 0.5, y - h, w, h, r, g, b, 1.0);

    // HP bar above the body, break bar under it: the two numbers the fight is
    // actually about. The end-of-turn actor also gets its name above the bar,
    // because "whose turn is it" is the one question the field cannot answer by
    // colour alone.
    local barWidth = w + 24.0;
    local barX = x - barWidth * 0.5;
    local hp = hudPoolMaximum(unit, "hp") > 0.0 ? hudPoolCurrent(unit, "hp") / hudPoolMaximum(unit, "hp") : 0.0;
    gfx.drawSolidRect(barX, y - h - 16.0, barWidth, 8.0, 0.12, 0.12, 0.14, 1.0);
    gfx.drawSolidRect(barX, y - h - 16.0, barWidth * hp, 8.0, 0.34, 0.76, 0.38, 1.0);
    local poise = unit.breakMax > 0 ? unit.breakValue.tofloat() / unit.breakMax.tofloat() : 0.0;
    gfx.drawSolidRect(barX, y + 4.0, barWidth, 6.0, 0.12, 0.12, 0.14, 1.0);
    gfx.drawSolidRect(barX, y + 4.0, barWidth * poise, 6.0, 0.85, 0.68, 0.24, 1.0);

    if (battleFight.pending != 0 && battleFight.pending == unit.id) {
        hudText(unit.displayName, barX, y - h - 40.0, 1.0, 0.94, 0.62, fit.scale * 1.2);
    }
}

function drawBattleHud(fit) {
    local uiDoc = Rpgc.get(battleFight.battle, "ui", 0);
    if (typeof uiDoc != "table") return;
    local party = Rpgc.get(uiDoc, "party", 0);
    if (typeof party != "table") return;

    local scale = fit.scale;
    local panelX = RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(party, "x", 0)));
    local panelY = RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(party, "y", 0)));
    local panelW = Rpgc.asNumber(Rpgc.get(party, "width", 0)) * scale;
    local panelH = Rpgc.asNumber(Rpgc.get(party, "height", 0)) * scale;
    local slotWidth = Rpgc.asNumber(Rpgc.get(party, "slotWidth", 0)) * scale;
    local slotGap = Rpgc.asNumber(Rpgc.get(party, "slotGap", 0)) * scale;
    local portraitHeight = Rpgc.asNumber(Rpgc.get(party, "portraitHeight", 0)) * scale;
    local slots = Rpgc.asInt(Rpgc.get(party, "slots", 0));
    local bars = Rpgc.get(party, "bars", []);

    local nameHeight = hudFont() != null ? 22.0 * scale : 0.0;
    local breakHeight = 9.0 * scale;
    local inset = 4.0 * scale;
    local labelScale = scale * 1.15;

    gfx.drawSolidRect(panelX, panelY, panelW, panelH, 0.05, 0.06, 0.09, 0.88);
    hudFrame(panelX, panelY, panelW, panelH, 2.0 * scale, 0.32, 0.34, 0.42, 0.95);

    for (local i = 0; i < slots; i += 1) {
        local cellX = panelX + i * (slotWidth + slotGap);
        local unit = unitAtSlot(RpgcBattle.allySide, i);

        // The bank is a CAP, not a roster: a position nobody fills is a legal
        // state and has to look like an empty seat rather than a missing plate.
        if (unit == 0) {
            gfx.drawSolidRect(cellX, panelY, slotWidth, portraitHeight, 0.08, 0.09, 0.11, 1.0);
            hudFrame(cellX, panelY, slotWidth, portraitHeight, 1.0 * scale, 0.20, 0.21, 0.26, 1.0);
            continue;
        }

        local active = battleFight.pending != 0 && battleFight.pending == unit.id;
        local colour = unit.alive ? hudElementColour(unit.element) : [0.24, 0.24, 0.27];

        // The portrait band, top to bottom: a name plate, the face, a break
        // strip. The workflow ships no character art (docs/11 §9), so the face
        // is the unit's element colour: it reads who is in the slot, whether the
        // slot is the one acting, and whether the member is still standing.
        local faceX = cellX + inset;
        local faceY = panelY + nameHeight;
        local faceW = slotWidth - inset * 2.0;
        local faceH = portraitHeight - nameHeight - breakHeight - inset * 2.0;
        if (faceH > 0.0 && faceW > 0.0) {
            gfx.drawSolidRect(faceX, faceY, faceW, faceH, colour[0], colour[1], colour[2], 1.0);
            // A darker skirt so the plate reads as a figure, not a swatch.
            gfx.drawSolidRect(faceX, faceY + faceH * 0.52, faceW, faceH * 0.48,
                colour[0] * 0.55, colour[1] * 0.55, colour[2] * 0.55, 1.0);
            hudFrame(faceX, faceY, faceW, faceH, 1.0 * scale, 0.10, 0.11, 0.14, 0.8);
        }

        gfx.drawSolidRect(cellX, panelY, slotWidth, nameHeight, 0.06, 0.07, 0.10, 1.0);
        if (nameHeight > 0.0) {
            hudText(unit.displayName, cellX + inset, panelY + 4.0 * scale,
                unit.alive ? 0.94 : 0.58, unit.alive ? 0.95 : 0.58, unit.alive ? 0.98 : 0.62,
                labelScale);
        }

        // 破绽: the bar the whole break chain is about. It lives inside the
        // portrait band because the document only budgets panel bars below it.
        local breakY = panelY + portraitHeight - breakHeight - inset;
        local breakRatio = unit.breakMax > 0
            ? unit.breakValue.tofloat() / unit.breakMax.tofloat() : 0.0;
        gfx.drawSolidRect(faceX, breakY, faceW, breakHeight, 0.10, 0.09, 0.07, 1.0);
        gfx.drawSolidRect(faceX, breakY, faceW * breakRatio, breakHeight, 0.88, 0.70, 0.24, 1.0);

        if (active) {
            hudFrame(cellX, panelY, slotWidth, portraitHeight, 2.0 * scale, 1.0, 0.92, 0.35, 1.0);
        } else if (!unit.alive && faceH > 0.0) {
            gfx.drawSolidRect(faceX, faceY, faceW, faceH, 0.06, 0.06, 0.08, 0.55);
        }

        // The document's bars, drawn at the document's offsets from the bottom
        // of the portrait strip, and labelled with the two numbers that make
        // them a readout instead of a coloured stripe.
        local budget = panelY + portraitHeight;
        foreach (bar in bars) {
            local barId = Rpgc.asString(Rpgc.get(bar, "id", ""));
            local barY = budget + Rpgc.asNumber(Rpgc.get(bar, "offsetY", 0)) * scale;
            local barH = Rpgc.asNumber(Rpgc.get(bar, "height", 0)) * scale;
            local colourBar = Rpgc.get(bar, "colour", [1.0, 1.0, 1.0]);
            local maximum = hudPoolMaximum(unit, barId);
            local current = hudPoolCurrent(unit, barId);
            local ratio = maximum > 0.0 ? current / maximum : 0.0;
            gfx.drawSolidRect(cellX, barY, slotWidth, barH, 0.10, 0.10, 0.12, 1.0);
            gfx.drawSolidRect(cellX, barY, slotWidth * ratio, barH,
                colourBar[0], colourBar[1], colourBar[2], 1.0);
            hudFrame(cellX, barY, slotWidth, barH, 1.0 * scale, 0.20, 0.21, 0.26, 0.9);
            local readout = "" + current.tointeger() + "/" + maximum.tointeger();
            local readoutH = barH * 0.62;
            hudReadout(readout, cellX + inset, barY + (barH - readoutH) * 0.5,
                readoutH, 0.96, 0.97, 1.0);
        }
    }

    // The command wheel: geometry from the document, one marker per key, and the
    // key number printed on the ones that are live. The HUD text line above the
    // screen says what the keys do; the numbers say WHICH key.
    local ring = Rpgc.get(uiDoc, "commandRing", 0);
    if (typeof ring != "table") return;
    local ringX = RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(ring, "cx", 0)));
    local ringY = RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(ring, "cy", 0)));
    local radius = Rpgc.asNumber(Rpgc.get(ring, "radius", 0)) * scale;
    gfx.drawSolidRect(ringX - radius, ringY - 1.0, radius * 2.0, 2.0, 0.25, 0.25, 0.30, 0.7);
    gfx.drawSolidRect(ringX - 1.0, ringY - radius, 2.0, radius * 2.0, 0.25, 0.25, 0.30, 0.7);
    local commands = battleCommandList();
    local buttons = Rpgc.get(ring, "buttons", []);
    for (local i = 0; i < buttons.len(); i += 1) {
        local buttonX = RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(buttons[i], "x", 0)));
        local buttonY = RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(buttons[i], "y", 0)));
        local buttonR = Rpgc.asNumber(Rpgc.get(buttons[i], "radius", 0)) * scale;
        local lit = i < commands.len();
        gfx.drawSolidRect(buttonX - buttonR, buttonY - buttonR, buttonR * 2.0, buttonR * 2.0,
            lit ? 0.92 : 0.22, lit ? 0.78 : 0.22, lit ? 0.30 : 0.26, 1.0);
        if (lit && i < 9) {
            local label = "" + (i + 1) + " " + commands[i].label;
            hudText(label, buttonX - buttonR, buttonY + buttonR + 4.0 * scale,
                1.0, 0.96, 0.78, scale * 1.05);
            hudReadout("" + (i + 1), buttonX - buttonR * 0.25, buttonY - buttonR * 0.55,
                buttonR * 0.7, 0.10, 0.10, 0.12);
        }
    }
}

function renderBattle() {
    local fit = battleFit();
    local viewW = gfx.getWidth().tofloat();
    local viewH = gfx.getHeight().tofloat();
    if (battleBackground != null) {
        gfx.drawTexturedRect(battleBackground, 0.0, 0.0, viewW, viewH, 1.0, 1.0, 1.0, 1.0);
    } else {
        gfx.drawSolidRect(0.0, 0.0, viewW, viewH, 0.07, 0.08, 0.11, 1.0);
    }

    // The two banks, drawn from `zones`: the left-top half is the enemy's and the
    // right-bottom half the party's, and the split is visible on purpose.
    local zones = Rpgc.get(battleFight.battle, "zones", 0);
    if (typeof zones == "table") {
        local enemy = Rpgc.get(zones, "enemy", 0);
        local ally = Rpgc.get(zones, "ally", 0);
        if (typeof enemy == "table") {
            gfx.drawSolidRect(RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(enemy, "x", 0))),
                RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(enemy, "y", 0))),
                Rpgc.asNumber(Rpgc.get(enemy, "width", 0)) * fit.scale,
                Rpgc.asNumber(Rpgc.get(enemy, "height", 0)) * fit.scale, 0.45, 0.15, 0.15, 0.16);
        }
        if (typeof ally == "table") {
            gfx.drawSolidRect(RpgcBattle.toScreenX(fit, Rpgc.asNumber(Rpgc.get(ally, "x", 0))),
                RpgcBattle.toScreenY(fit, Rpgc.asNumber(Rpgc.get(ally, "y", 0))),
                Rpgc.asNumber(Rpgc.get(ally, "width", 0)) * fit.scale,
                Rpgc.asNumber(Rpgc.get(ally, "height", 0)) * fit.scale, 0.15, 0.28, 0.45, 0.16);
        }
    }

    foreach (unit in battleFight.units) drawBattleUnit(unit, fit);
    drawBattleHud(fit);
}


// Sample gameplay wiring: dialogue commits intent; the quest module owns all
// objective counting, capacity checks and atomic reward/claimed transitions.
function setupWorldQuests() {
    local loaded=RpgcProject.loadKind("quest");
    if (!loaded.ok) throw "quest definitions failed: "+Rpgc.summary(loaded);
    worldQuestDocs=loaded.value; worldGuideQuest=null;
    foreach (doc in worldQuestDocs) if (doc.id=="quest.toolkit-guide") worldGuideQuest=doc;
}
function processWorldQuests() {
    if (worldQuestError!="") return;
    if (worldGuideQuest!=null && worldState.variables.rawin("toolkit.guide.accepted") &&
        worldState.variables.rawget("toolkit.guide.accepted")==1 && !worldState.quests.rawin(worldGuideQuest.id)) {
        local activated=RpgcQuests.activate(worldGuideQuest,worldState);
        if (!activated.ok) say("任务接取失败："+Rpgc.summary(activated));
        else {
            foreach (event in activated.value.domainEvents) {
                worldDomainEvents.append(event);
                if (event.kind=="quest_completed") dispatchWorldTrigger("quest_completed",event.payload.questId);
            }
            print("[rpgc-runtime] quest activated "+worldGuideQuest.id+"\n");
        }
    }
    if (worldDomainEvents.len()>0) {
        local input=worldDomainEvents;
        local consumedEvents=RpgcQuests.consume(worldQuestDocs,worldState,input);
        if (!consumedEvents.ok) { worldQuestError=Rpgc.summary(consumedEvents); say("任务计数暂停："+worldQuestError+"；按 T 重试。"); return; }
        worldDomainEvents=[];
        foreach (event in consumedEvents.value.domainEvents) {
            worldDomainEvents.append(event);
            if (event.kind=="quest_completed") {
                dispatchWorldTrigger("quest_completed",event.payload.questId);
                say("任务目标完成，按 T 返回向导领奖。");
                print("[rpgc-runtime] quest completed "+event.payload.questId+"\n");
            }
        }
        syncWorldPresentation(); rememberWorldState();
    }
}
function visitWorldGuide() {
    worldQuestError="";
    processWorldQuests();
    if (worldGuideQuest!=null && worldState.quests.rawin(worldGuideQuest.id) &&
        worldState.quests.rawget(worldGuideQuest.id).status=="completed") {
        local claimed=RpgcQuests.claim(worldGuideQuest,worldState,itemsConfig==null ? 0 : itemsConfig);
        if (!claimed.ok) { say("奖励尚未领取："+Rpgc.summary(claimed)); return false; }
        foreach (event in claimed.value.domainEvents) worldDomainEvents.append(event);
        syncWorldPresentation(); saveBag();
        say("已领取向导奖励：5 金币、1 份金创药。");
        print("[rpgc-runtime] quest claimed "+worldGuideQuest.id+"\n");
        return true;
    }
    return openWorldDialogue("dialogue.toolkit-guide");
}
function worldQuestSummary() {
    if (worldGuideQuest==null) return "";
    if (!worldState.quests.rawin(worldGuideQuest.id)) return "向导委托：按 T 对话接取";
    local progress=worldState.quests.rawget(worldGuideQuest.id);
    local label=progress.status;
    if (label=="active") label="寻找并打开村外旧箱子";
    if (label=="completed") label="目标完成，按 T 领奖";
    if (label=="claimed") label="奖励已领取";
    return worldGuideQuest.title+"："+label;
}

// Player save files are independent of the persist-only hot-reload snapshot.
function worldSaveContext() {
    return {eventActive=worldSession!=null || worldQueue.len()>0 || worldMessage!=null || worldCameraTween!=null || worldAcks.len()>0 || worldRuntimeFatal!="",
        dialogueActive=worldDialogue!=null,battleActive=battleFight!=null,
        pendingDomainEvents=worldDomainEvents.len()>0 || worldQuestError!="",pendingTransfer=pendingMapEntered!=""};
}
function worldSaveMeta() { return {partyId=PARTY_ID,locale=worldLocale,inputSequence=worldInputSequence}; }
function processWorldSave() {
    if(!worldSaveRequested)return null;
    local captured=RpgcSave.capture(worldState,itemEquip,worldSaveMeta(),worldSaveContext());
    if(!captured.ok) {
        worldSaveRequested=false;worldSaveLastResult=captured;worldSaveStatus="保存失败："+Rpgc.summary(captured);say(worldSaveStatus);return captured;
    }
    if(captured.value.status=="deferred") {
        worldSaveStatus="等待安全点保存："+captured.value.reason;worldSaveLastResult=captured;return captured;
    }
    local saved=RpgcSaveStore.save(captured.value.snapshot,"slot1");
    worldSaveRequested=false;worldSaveLastResult=saved;
    worldSaveStatus=saved.ok ? "已保存到玩家存档槽 1" : "保存失败："+Rpgc.summary(saved);
    say(worldSaveStatus);return saved;
}
function requestWorldSave() {
    worldSaveRequested=true;
    local result=processWorldSave();
    if(worldSaveRequested)say(worldSaveStatus);
    return result;
}
function applyWorldRestore(candidate) {
    // Strict source validation happens in RpgcSave.restore before this function.
    // Native map admission remains a second gate, before swapping live values.
    if(candidate.partyId!=PARTY_ID)return Rpgc.fail([Rpgc.error("save.party-adapter","this game adapter only supports its configured party","/payload/partyId","")]);
    local oldMap=worldState.mapId;local oldX=worldState.x;local oldY=worldState.y;
    local oldFX=worldState.facingX;local oldFY=worldState.facingY;
    local loaded=false;local errorText="saved map or landing cell was rejected";
    try {loaded=loadWorldMap(candidate.state.mapId,candidate.state.x,candidate.state.y,candidate.state.facingX,candidate.state.facingY,true);}
    catch(error){errorText="saved map admission failed: "+error;}
    if(!loaded) {
        local restored=false;
        try {restored=loadWorldMap(oldMap,oldX,oldY,oldFX,oldFY,true);}catch(error){restored=false;}
        if(!restored)worldRuntimeFatal="读档地图失败且旧地图无法恢复；原世界状态未替换。";
        return Rpgc.fail([Rpgc.error("save.map-adapter",errorText+(restored ? "; previous map restored" : "; previous map rollback failed"),"/payload/world/mapId","")]);
    }
    worldState=candidate.state;itemEquip=candidate.equipment;worldLocale=candidate.locale;worldInputSequence=candidate.inputSequence;
    worldSession=null;worldQueue=[];worldQueued={};worldAcks=[];worldDomainEvents=[];
    worldDialogue=null;worldMessage=null;worldCameraTween=null;pendingMapEntered="";
    worldQuestError="";worldRuntimeFatal="";worldSaveRequested=false;activePath=null;bagOpen=false;
    foreach(actorId,actor in worldActors){actor.player.stop();actor.operationId="";}
    syncWorldPresentation();saveBag();rememberWorldState();
    return Rpgc.ok({restored=true,mapId=worldState.mapId});
}
function requestWorldLoad() {
    local context=worldSaveContext();
    foreach(key,busy in context)if(busy) {
        local denied=Rpgc.fail([Rpgc.error("save.busy","loading is only allowed at a safe point: "+key,"$","")]);
        worldSaveLastResult=denied;worldSaveStatus="当前正在进行游戏动作，安全点才能读档。";say(worldSaveStatus);return denied;
    }
    local loaded=RpgcSaveStore.load("slot1");
    if(!loaded.ok){worldSaveLastResult=loaded;worldSaveStatus="读档失败："+Rpgc.summary(loaded);say(worldSaveStatus);return loaded;}
    local restored=applyWorldRestore(loaded.value.candidate);
    if(restored.ok){restored.value.source<-loaded.value.source;restored.value.directory<-loaded.value.directory;}
    worldSaveLastResult=restored;
    worldSaveStatus=restored.ok ? (loaded.value.source=="backup" ? "主存档损坏或缺失，已恢复上一代有效备份。" : "已读取玩家存档槽 1") : "读档失败："+Rpgc.summary(restored);
    say(worldSaveStatus);return restored;
}

function initializeWorldRuntime() {
    local initial=RpgcWorldState.create({gold=gold,mapId=worldMapId,x=playerX<0 ? 0 : playerX,y=playerY<0 ? 0 : playerY,
        facingX=facingX,facingY=facingY,moment="day"});
    if (worldRuntimeSnapshot!="") {
        local saved=RpgcJson.parse(worldRuntimeSnapshot);
        if (saved.ok) {
            saved.value.activeEvents<-{};
            local restored=RpgcWorldState.create(saved.value);
            if (restored.ok) initial=restored;
            else throw "world hot-reload state rejected: "+Rpgc.summary(restored);
        } else throw "world hot-reload state is not valid JSON";
    }
    if (!initial.ok) throw "world state rejected: "+Rpgc.summary(initial);
    worldState=initial.value;
    // First launch retains the existing -1 spawn sentinel; reload uses shared coordinates.
    if (worldRuntimeSnapshot!="") syncWorldPresentation();
    worldAnimation=eve.Animation();
    local messages=RpgcJson.parse(eve.Filesystem().readText("data/story-messages.json"));
    if (!messages.ok || typeof messages.value!="table") throw "missing or invalid story message catalog";
    worldMessages=messages.value;
}
function worldDialoguePanel() {
    if (worldMessage!=null) return worldMessage.text+"\n[空格 / Enter 继续 · Esc 取消]";
    if (worldDialogue==null || worldDialogue.view==null) return "";
    local view=worldDialogue.view;
    local text=(view.speaker=="" ? "" : view.speaker+"：\n")+view.text;
    for (local i=0;i<view.options.len();i+=1) text+="\n"+(i+1)+". "+view.options[i].text;
    text+=view.kind=="line" ? "\n[空格 / Enter 继续 · L 切换语言 · Esc 取消]" : "\n[数字键选择 · L 切换语言 · Esc 取消]";
    return text;
}
function handleWorldInput() {
    if (keyPressed("escape")) { cancelWorldEvent(); return; }
    if (keyPressed("l") || keyPressed("L")) {
        worldLocale=worldLocale=="zh-CN" ? "en" : "zh-CN";
        refreshWorldDialogue();
    }
    local advance=keyPressed("space") || keyPressed("return") || keyPressed("enter");
    if (worldMessage!=null && advance) {
        worldAck(worldMessage.request,true); worldMessage=null; return;
    }
    if (worldDialogue!=null) {
        if (advance) worldDialogueInput(-1,true);
        for (local i=0;i<9;i+=1) if (keyPressed(""+(i+1))) worldDialogueInput(i,false);
    }
}
function positionWorldSprites() {
    foreach (actorId,actor in worldActors) {
        local cell=worldActorPosition(actorId);
        if (cell==null || battleFight!=null || worldLayer==null || camera==null) { actor.sprite.setVisible(false); continue; }
        actor.sprite.setVisible(true);
        local wx=worldLayer.tileToWorldX(cell.x,cell.y);
        local wy=worldLayer.tileToWorldY(cell.x,cell.y);
        actor.sprite.setPosition(camera.worldToScreenX(wx,wy,gfx.getWidth().tofloat(),gfx.getHeight().tofloat()),
            camera.worldToScreenY(wx,wy,gfx.getWidth().tofloat(),gfx.getHeight().tofloat()));
        actor.sprite.setScale(camera.getZoom(),camera.getZoom());
    }
}

function buildHud() {
    if (hudBuilt) return;
    ui.beginBuild();
    ui.beginWindow("rpg-classic", "root");
    ui.text("", "area");
    ui.text("方向键 / WASD 移动 · E 互动 · T 向导 · B 战斗 · I 背包 · F5 保存 · F9 读档", "help");
    ui.text("", "battle");
    ui.text("", "items");
    ui.text("", "status");
    ui.text("", "dialogue");
    ui.end();
    ui.mountBuildAs("hud");
    ui.select("hud");
    ui.setHostOverlay(true);
    ui.setHostPos(16.0, 12.0, 0.0, 0.0);
    hudBuilt = true;
}

function setupGame() {
    local firstLaunch=worldRuntimeSnapshot=="";
    initializeWorldRuntime();
    loadObjectContract();
    loadEventDocs();
    setupItems();
    if (itemBag!=null) worldState.bag=itemBag;
    setupWorldQuests();
    gfx.setBackgroundColor(0.05, 0.07, 0.10, 1.0);
    local startX = playerX;
    local startY = playerY;
    if (!loadWorldMap(worldMapId, startX, startY, facingX, facingY))
        throw "rpgc: failed to load " + worldMapId;
    commitPlayerPosition();
    buildHud();
    if (firstLaunch) dispatchWorldTrigger("game_started");
    dispatchWorldTrigger("map_entered");
    if (statusText == "") say("村庄外郊。去找长者，或走向森林入口。");
    refreshHud();
}

eve_init = function () {
    setupGame();
};

eve_reload <- function () {
    hudBuilt = false;
    battleFight = null;
    battleExtra = "";
    battleBackground = null;
    battleBackgroundPath = "";
    bagOpen = false;
    setupGame();
};

eve_update = function (dt) {
    if(keyPressed("f5") || keyPressed("F5"))requestWorldSave();
    if(keyPressed("f9") || keyPressed("F9")){requestWorldLoad();refreshHud();return;}
    if (battleFight != null) {
        updateBattle(dt);
        if (statusTimer > 0.0) {
            statusTimer -= dt;
            if (statusTimer <= 0.0) statusText = "";
        }
        refreshHud();
        return;
    }
    if (worldLayer == null) return;
    if (worldRuntimeFatal!="") { statusText=worldRuntimeFatal; refreshHud(); return; }
    if (statusTimer > 0.0) {
        statusTimer -= dt;
        if (statusTimer <= 0.0) statusText = "";
    }

    updateWorldEvents(dt);
    processWorldQuests();
    processWorldSave();
    if (worldBusy()) {
        handleWorldInput();
        map.update(dt); refreshHud(); return;
    }
    if (keyPressed("t") || keyPressed("T")) {
        visitWorldGuide(); refreshHud(); return;
    }
    if (keyPressed("b") || keyPressed("B")) {
        startBattle();
        return;
    }

    // The bag panel takes the keyboard while it is open: the digits then pick a
    // row instead of walking. Closing it is the same key, so there is no state
    // the player can be stuck in.
    if (keyPressed("i") || keyPressed("I")) {
        bagOpen = !bagOpen;
        refreshHud();
        return;
    }
    if (bagOpen) {
        for (local i = 0; i < 9; i += 1) {
            if (!keyPressed("" + (i + 1))) continue;
            bagAct(i);
            refreshHud();
            return;
        }
        return;
    }

    local dx = 0;
    local dy = 0;
    if (keyPressed("left") || keyPressed("a") || keyPressed("A")) dx = -1;
    if (keyPressed("right") || keyPressed("d") || keyPressed("D")) dx = 1;
    if (keyPressed("up") || keyPressed("w") || keyPressed("W")) dy = -1;
    if (keyPressed("down") || keyPressed("s") || keyPressed("S")) dy = 1;
    if (dx != 0 && dy != 0) dy = 0;
    tryMove(dx, dy);

    local mouseDown = mouse.isDown(1);
    if (mouseDown && !previousMouseDown && camera != null) {
        local viewW = gfx.getWidth().tofloat();
        local viewH = gfx.getHeight().tofloat();
        local wx = camera.screenToWorldX(mouse.getX().tofloat(), mouse.getY().tofloat(), viewW, viewH);
        local wy = camera.screenToWorldY(mouse.getX().tofloat(), mouse.getY().tofloat(), viewW, viewH);
        requestPath(worldLayer.worldToTileX(wx, wy), worldLayer.worldToTileY(wx, wy));
    }
    previousMouseDown = mouseDown;

    if (activePath != null && pathIndex > 0 && pathIndex < activePath.getLength()) {
        stepClock += dt;
        if (stepClock >= STEP_SECONDS) {
            stepClock = 0.0;
            playerX = activePath.getX(pathIndex);
            playerY = activePath.getY(pathIndex);
            pathIndex += 1;
            commitPlayerPosition();
            followCamera();
            if (pathIndex >= activePath.getLength()) activePath = null;
        }
    }

    local standing = objectAtPlayer();
    local standingPortal = standing >= 0 && map.getObjectType(standing) == "portal";
    if (standingPortal && !onPortal) enterPortal(standing);
    onPortal = standingPortal;

    if (keyPressed("e") || keyPressed("E")) interactObject(nearestObject(INTERACT_RANGE));

    map.update(dt);
    refreshHud();
};

function markerColor(kind) {
    if (kind == "npc") return [0.95, 0.82, 0.28, 1.0];
    if (kind == "chest") return [0.92, 0.55, 0.18, 1.0];
    if (kind == "portal") return [0.35, 0.78, 0.95, 1.0];
    return [0.7, 0.7, 0.7, 1.0];
}

eve_render = function () {
    worldRenderedFrames+=1;
    gfx.clear();
    if (battleFight != null) {
        renderBattle();
        ui.beginFrameAndRender();
        return;
    }
    map.render(gfx);
    if (worldLayer != null && camera != null) {
        local viewW = gfx.getWidth().tofloat();
        local viewH = gfx.getHeight().tofloat();
        for (local i = 0; i < map.getObjectCount(); i += 1) {
            local kind = map.getObjectType(i);
            if (kind == "spawn") continue;
            if (kind == "chest" && (consumedKey(worldMapId, map.getObjectName(i)) in consumed)) continue;
            local cell = objectTile(i);
            local wx = worldLayer.tileToWorldX(cell.x, cell.y);
            local wy = worldLayer.tileToWorldY(cell.x, cell.y);
            local sx = camera.worldToScreenX(wx, wy, viewW, viewH);
            local sy = camera.worldToScreenY(wx, wy, viewW, viewH);
            local color = markerColor(kind);
            gfx.drawSolidRect(sx - 6.0, sy - 6.0, 12.0, 12.0, color[0], color[1], color[2], color[3]);
            local actorId=map.getObjectName(i);
            if (actorFacings.rawin(actorId)) {
                local direction=actorFacings.rawget(actorId);
                gfx.drawSolidRect(sx+direction.x*12.0-2.0,sy+direction.y*12.0-2.0,4.0,4.0,1.0,1.0,1.0,1.0);
            }
        }
        local px = worldLayer.tileToWorldX(playerX, playerY);
        local py = worldLayer.tileToWorldY(playerX, playerY);
        local sx = camera.worldToScreenX(px, py, viewW, viewH);
        local sy = camera.worldToScreenY(px, py, viewW, viewH);
        if (!worldActors.rawin("player")) gfx.drawSolidRect(sx - 8.0, sy - 22.0, 16.0, 28.0, 0.95, 0.35, 0.28, 1.0);
    }
    positionWorldSprites();
    gfx.renderSprites();
    ui.beginFrameAndRender();
};
