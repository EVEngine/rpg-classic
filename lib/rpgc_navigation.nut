// Shared game/QA adapter. Native Map and Pathfinder remain authoritative.
import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcTilemap } from "./rpgc_tilemap.nut"

export class RpgcNavigation {}

RpgcNavigation.atlasRules <- function(path) {
    local parsed=RpgcJson.parse(eve.Filesystem().readText(path));
    if (!parsed.ok) throw "navigation: invalid map " + path;
    local sets=Rpgc.get(parsed.value,"tilesets",[]);
    if (sets.len()!=1) throw "navigation: exactly one tileset required";
    local source=Rpgc.asString(Rpgc.get(sets[0],"source",""));
    local atlasPath="content/tilesets/"+Rpgc.stem(source)+".json";
    local cut=source.find("tilesets/");
    if(cut!=null) atlasPath="content/"+source.slice(cut);
    local atlas=RpgcJson.parse(eve.Filesystem().readText(atlasPath));
    if(!atlas.ok) throw "navigation: invalid tileset " + atlasPath;
    local rules={};
    foreach(tile in RpgcTilemap.tilesOf(atlas.value)) {
        local gid=Rpgc.asInt(Rpgc.get(tile,"gid",0));
        if(gid>0) rules[""+gid]<-{walkable=Rpgc.get(tile,"walkable",true)?true:false,cost=Rpgc.get(tile,"cost",1.0)};
    }
    return rules;
}

RpgcNavigation.apply <- function(layer,pathfinder,rules) {
    pathfinder.setDiagonal(false);
    pathfinder.setBlockEmpty(true);
    foreach(key,tile in rules) if(!tile.walkable) pathfinder.blockGid(key.tointeger());
    pathfinder.syncFromLayer();
    for(local y=0;y<layer.getMapHeight();y+=1) for(local x=0;x<layer.getMapWidth();x+=1) {
        local key=""+layer.getTile(x,y);
        if(key in rules && rules[key].walkable) pathfinder.setCellCost(x,y,rules[key].cost*1.0);
    }
}

// eve.Map is a shared native module. Returned layer/pathfinder handles are
// current-map handles, not independent snapshots; reload before another map query.
RpgcNavigation.load <- function(mapId) {
    local path="content/maps/"+mapId+".json";
    local rules=this.atlasRules(path);
    local map=eve.Map();
    local loaded=map.loadFromFileWithObjectContract(path,eve.Filesystem().readText("data/world-object-contract.json"));
    if(!loaded.ok) throw "navigation: map rejected: "+loaded.status.summary;
    local layer=map.getLayer(0);
    if(layer==null) throw "navigation: missing terrain layer";
    local pathfinder=map.newPathfinder(layer);
    if(pathfinder==null) throw "navigation: native pathfinder unavailable";
    this.apply(layer,pathfinder,rules);
    return {map=map,layer=layer,pathfinder=pathfinder};
}

// Project presentation convention shared by game and standalone map preview.
RpgcNavigation.configureLayers <- function(map,camera) {
    for(local i=0;i<map.getLayerCount();i+=1) {
        local layer=map.getLayer(i);
        if(layer!=null) {layer.setCamera(camera);layer.setVisualScale(2.0,2.0);}
    }
}
