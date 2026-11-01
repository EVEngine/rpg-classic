// Structural map QA through the same native adapter as the game.
// No Python projection, collision grid or pathfinding implementation.
import { Rpgc } from "./rpgc_core.nut"
import { RpgcProject } from "./rpgc_project.nut"
import { RpgcValidate } from "./rpgc_validate.nut"
import { RpgcNavigation } from "./rpgc_navigation.nut"

export class RpgcMapQA {}

RpgcMapQA.reachable <- function(pf,sx,sy,x,y) {
    if(!pf.isWalkable(sx,sy) || !pf.isWalkable(x,y)) return false;
    if(sx==x && sy==y) return true;
    local path=pf.findPath(sx,sy,x,y);
    return path!=null && path.getLength()>0;
}

RpgcMapQA.inspect <- function(mapId) {
    local loaded=RpgcProject.loadById("map",mapId);
    if(!loaded.ok) return loaded;
    local gate=RpgcValidate.validateDocument("map",loaded.value);
    if(!gate.ok) return Rpgc.fail(gate.diagnostics);
    local doc=loaded.value;
    local native=RpgcNavigation.load(mapId);
    local map=native.map;local layer=native.layer;local pf=native.pathfinder;
    local width=layer.getMapWidth();local height=layer.getMapHeight();
    if(width*height>65536) throw "map QA supports at most 65536 cells";
    local diagnostics=[];local objects=[];local walkable=[];
    local paths={};
    for(local li=0;li<doc.layers.len();li+=1) {
        local group=doc.layers[li];
        if(Rpgc.get(group,"type","")!="objectgroup") continue;
        for(local oi=0;oi<group.objects.len();oi+=1)
            paths[group.objects[oi].name]<-"/layers/"+li+"/objects/"+oi;
    }
    local at="content/maps/"+mapId+".json";
    local issue=function(code,message,pointer,severity="error") {
        diagnostics.append({code=code,message=message,path=pointer,document=at,severity=severity});
    };
    local sx=-1;local sy=-1;
    local spawn=map.findObjectByName("spawn");
    if(spawn>=0) {
        sx=layer.worldToTileX(map.getObjectX(spawn),map.getObjectY(spawn));
        sy=layer.worldToTileY(map.getObjectX(spawn),map.getObjectY(spawn));
    }
    if(!pf.isWalkable(sx,sy)) issue("map-qa.spawn-blocked","authored spawn is outside the map or blocked",spawn>=0?paths["spawn"]:"/layers");
    local roundtrips=0;local badPicks=0;local walkableCount=0;
    for(local y=0;y<height;y+=1) {
        local row=[];
        for(local x=0;x<width;x+=1) {
            local passable=pf.isWalkable(x,y);row.append(passable);if(passable) walkableCount+=1;
            local wx=layer.tileToWorldX(x,y)+layer.getTileWidth()*0.5;
            local wy=layer.tileToWorldY(x,y)+layer.getTileHeight()*0.5;
            if(layer.worldToTileX(wx,wy)!=x || layer.worldToTileY(wx,wy)!=y) badPicks+=1;
            roundtrips+=1;
        }
        walkable.append(row);
    }
    if(badPicks>0) issue("map-qa.pick-mismatch","native logical cell-center picking disagrees for "+badPicks+" cells","/renderSpacing");
    local occupied={};
    for(local i=0;i<map.getObjectCount();i+=1) {
        local name=map.getObjectName(i);local kind=map.getObjectType(i);
        local x=layer.worldToTileX(map.getObjectX(i),map.getObjectY(i));
        local y=layer.worldToTileY(map.getObjectX(i),map.getObjectY(i));
        local pointer=paths[name];local reachable=false;
        // The game interacts within Chebyshev distance one, even diagonally.
        // Portals also auto-enter when standing on the portal cell.
        local radius=(kind=="npc" || kind=="chest")?1:0;
        for(local dy=-radius;dy<=radius;dy+=1) for(local dx=-radius;dx<=radius;dx+=1)
            if(this.reachable(pf,sx,sy,x+dx,y+dy)) reachable=true;
        if(x<0 || y<0 || x>=width || y>=height)
            issue("map-qa.object-outside","object "+name+" is outside the native grid",pointer);
        else if(!reachable && kind!="spawn")
            issue("map-qa.object-unreachable","no native path from spawn to interaction point for "+name,pointer);
        local key=x+","+y;
        if(key in occupied) issue("map-qa.object-overlap","objects share a cell: "+occupied[key]+" and "+name,pointer,"warning");
        else occupied[key]<-name;
        local object={name=name,type=kind,x=x,y=y,path=pointer,reachable=reachable,
            moment=map.getObjectProperty(i,"moment","")};
        if(kind=="portal") {
            object.targetMap<-map.getObjectProperty(i,"targetMap","");
            object.targetX<-map.getObjectProperty(i,"targetX","-1").tointeger();
            object.targetY<-map.getObjectProperty(i,"targetY","-1").tointeger();
        }
        objects.append(object);
    }
    return Rpgc.result({id=mapId,width=width,height=height,spawn={x=sx,y=sy},objects=objects,
        walkable=walkable,walkableCount=walkableCount,projectionChecks=roundtrips,pickMismatches=badPicks},diagnostics);
}

// Avoid `project`: the current SDK resolves this imported dynamic method
// name against a native signature and rejects string arguments at the caller.
RpgcMapQA.auditProject <- function(selected) {
    local maps={};local diagnostics=[];local ids=RpgcProject.idsOf("map");ids.sort();
    if(selected!="" && ids.find(selected)==null)
        return Rpgc.fail([Rpgc.error("map-qa.unknown-map","unknown map "+selected,"/id","")]);
    foreach(id in ids) {
        try {
            local result=this.inspect(id);
            if(result.value!=0) maps.rawset(id,result.value);
            foreach(d in result.diagnostics) {
                if(!("document" in d)) d.document<-"content/maps/"+id+".json";
                if(selected=="" || selected==id) diagnostics.append(d);
            }
            // Keep load errors of destinations visible even for single-map QA.
            if(result.value==0 && selected!="" && selected!=id)
                maps.rawset(id,{unavailable=true});
        } catch(error) {
            maps.rawset(id,{unavailable=true});
            if(selected=="" || selected==id) diagnostics.append({severity="error",code="map-qa.native-load",
                path="/",document="content/maps/"+id+".json",message=""+error});
        }
    }
    local edges=[];local output=[];
    foreach(id in ids) {
        if(!(id in maps) || "unavailable" in maps.rawget(id)) continue;
        local report=maps.rawget(id);
        foreach(object in report.objects) if(object.type=="portal") {
            local valid=false;local connected=false;
            if(object.targetMap in maps && !("unavailable" in maps.rawget(object.targetMap))) {
                local target=maps.rawget(object.targetMap);local x=object.targetX;local y=object.targetY;
                valid=x>=0 && y>=0 && x<target.width && y<target.height && target.walkable[y][x];
                if(valid) {
                    // Native map/pathfinder handles are invalidated by later map loads.
                    // Query immediately; never retain handles across destinations.
                    local native=RpgcNavigation.load(object.targetMap);
                    connected=this.reachable(native.pathfinder,target.spawn.x,target.spawn.y,x,y);
                }
            }
            object.landingWalkable<-valid;
            object.landingConnectedToSpawn<-connected;
            edges.append({source=id,target=object.targetMap,path=object.path,usable=valid && connected && object.reachable});
            if(!valid && (selected=="" || selected==id)) diagnostics.append({severity="error",
                code="map-qa.portal-landing",document="content/maps/"+id+".json",path=object.path+"/properties",
                message="portal "+object.name+" has missing or blocked destination "+object.targetMap+" ("+object.targetX+","+object.targetY+")"});
            if(valid && !connected && (selected=="" || selected==id)) diagnostics.append({severity="error",
                code="map-qa.portal-isolated",document="content/maps/"+id+".json",path=object.path+"/properties",
                message="portal "+object.name+" lands on a walkable island disconnected from the destination spawn"});
        }
        if(selected=="" || selected==id) output.append(report);
    }
    // Directed structural graph from the explicitly selected map or canonical first map.
    local origin=selected!=""?selected:(ids.len()>0?ids[0]:"");
    local seen={};if(origin!="") seen[origin]<-true;
    for(local pass=0;pass<ids.len();pass+=1)
        foreach(edge in edges) if(edge.usable && edge.source in seen) seen[edge.target]<-true;
    local unreachable=[];
    foreach(id in ids) if(!(id in seen)) unreachable.append(id);
    return Rpgc.result({maps=output,graph={origin=origin,edges=edges,unreachable=unreachable},
        scope="structural",rendered=false,capabilities={nativeLoading=true,nativePathfinding=true,nativePicking=true,
            stateConditions=false,objectFootprints=false},
        limitations=["Structural reachability only; event transfers and conditional gates are not simulated.",
            "Objects use the game's point anchors; area footprints are not collision bodies."]},diagnostics);
}
