"""Native, single-purpose map inspector app source (no geometry in Python)."""
import json
from .map_qa import map_id


def preview_source(identifier, context=None):
    if not map_id(identifier):
        raise ValueError('preview requires a map ID')
    payload = json.dumps(json.dumps(context or {}, ensure_ascii=False, allow_nan=False), ensure_ascii=False)
    return SOURCE.replace('MAP_ID_LITERAL', json.dumps(identifier)).replace('CONTEXT_LITERAL', payload)


SOURCE = r'''import { RpgcNavigation } from "game:/lib/rpgc_navigation.nut"
import { RpgcMapQA } from "game:/lib/rpgc_map_qa.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { Rpgc } from "game:/lib/rpgc_core.nut"
PreviewContext <- RpgcJson.parse(CONTEXT_LITERAL).value;
PreviewNative <- null; PreviewCamera <- null; PreviewGfx <- null;
PreviewFrames <- 0; PreviewError <- ""; PreviewQA <- null; PreviewReport <- null;
PreviewUI <- null; PreviewMouse <- null; PreviewKeyboard <- null;
PreviewMouseDown <- false; PreviewKeys <- {}; PreviewInspector <- Rpgc.get(PreviewContext,"inspector",true);
PreviewState <- {blocked=true,objects=true,changes=true,selectedX=-1,selectedY=-1,selectedObject=-1,selectionCount=0,zoom=1.0};
PreviewCells <- []; PreviewDiagnostics <- []; PreviewObjectChanges <- 0;

function previewFit() {
    local l=PreviewNative.layer;local w=l.getMapWidth();local h=l.getMapHeight();
    local minX=100000000.0;local maxX=-100000000.0;local minY=100000000.0;local maxY=-100000000.0;
    foreach(point in [[0,0],[w-1,0],[0,h-1],[w-1,h-1]]) {
        local x=l.tileToWorldX(point[0],point[1]);local y=l.tileToWorldY(point[0],point[1]);
        if(x<minX)minX=x;if(x>maxX)maxX=x;if(y<minY)minY=y;if(y>maxY)maxY=y;
    }
    maxX+=l.getTileWidth()*2.0;maxY+=l.getTileHeight()*2.0;
    local availableW=PreviewGfx.getWidth()-(PreviewInspector?360.0:0.0);
    local availableH=PreviewGfx.getHeight()-(PreviewInspector?130.0:0.0);
    local zx=availableW*0.90/(maxX-minX);local zy=availableH*0.90/(maxY-minY);
    local zoom=zx<zy?zx:zy;PreviewCamera.setZoom(zoom);PreviewState.zoom=zoom;
    PreviewCamera.setPosition((minX+maxX)*0.5-(PreviewInspector?180.0:0.0)/zoom,(minY+maxY)*0.5);
}
function previewSelect(x,y,index=-1) {
    if(x<0 || y<0 || x>=PreviewReport.width || y>=PreviewReport.height)return false;
    PreviewState.selectedX=x;PreviewState.selectedY=y;PreviewState.selectedObject=index;
    PreviewState.selectionCount+=1;return true;
}
function previewAction(action,arg=0) {
    if(PreviewNative==null)return false;
    if(action=="blocked")PreviewState.blocked=!PreviewState.blocked;
    else if(action=="objects")PreviewState.objects=!PreviewState.objects;
    else if(action=="changes")PreviewState.changes=!PreviewState.changes;
    else if(action=="fit")previewFit();
    else if(action=="zoom-in" || action=="zoom-out") {
        local z=PreviewCamera.getZoom()*(action=="zoom-in"?1.25:0.8);
        if(z<0.02 || z>8.0)return false;
        PreviewCamera.setZoom(z);PreviewState.zoom=z;
    } else if(action=="select-object") {
        if(typeof arg!="integer" || arg<0 || arg>=PreviewReport.objects.len())return false;
        local obj=PreviewReport.objects[arg];return previewSelect(obj.x,obj.y,arg);
    } else if(action=="select-cell") {
        if(typeof arg!="integer" || arg<0 || arg>=PreviewReport.width*PreviewReport.height)return false;
        return previewSelect(arg%PreviewReport.width,arg/PreviewReport.width);
    } else if(action=="diagnostic") {
        if(typeof arg!="integer" || arg<0 || arg>=PreviewDiagnostics.len())return false;
        local d=PreviewDiagnostics[arg];
        if(Rpgc.get(d,"document","")!="content/maps/"+MAP_ID_LITERAL+".json")return false;
        for(local i=0;i<PreviewReport.objects.len();i+=1) {
            local obj=PreviewReport.objects[i];local at=Rpgc.get(d,"path","");
            if(at==obj.path || at.find(obj.path+"/")==0)return previewSelect(obj.x,obj.y,i);
        }
        return false;
    } else return false;
    return true;
}
function previewCallback(action,arg) {return function(){previewAction(action,arg);};}
function previewUiBuild() {
    local u=PreviewUI;
    u.beginBuild();u.beginWindow("地图检查器", "root");
    u.text("RPG CLASSIC  /  地图检查器", "brand");
    u.text(MAP_ID_LITERAL,"map-id");
    u.text("", "summary");u.text("", "quality");u.text("", "diff");
    u.text("显示图层", "layers-title");
    u.button("", "blocked");u.button("", "objects");u.button("", "changes");
    u.beginRow("zoom-row",6.0);u.button("缩小 -", "zoom-out");u.button("适配 R", "fit");u.button("放大 +", "zoom-in");u.end();
    u.text("选择对象", "objects-title");
    for(local i=0;i<PreviewReport.objects.len();i+=1) {
        local object=PreviewReport.objects[i];
        u.button(object.name+"  ["+object.type+"]", "object-"+i);
    }
    u.text("", "selection");
    u.text("QA 诊断 / 点击定位", "diagnostics-title");
    if(PreviewDiagnostics.len()==0)u.text("未发现结构问题", "no-errors");
    for(local i=0;i<PreviewDiagnostics.len();i+=1) {
        local d=PreviewDiagnostics[i];u.button(d.severity+": "+d.code,"diagnostic-"+i);
    }
    u.text("", "diagnostic-detail");
    u.end();u.mountBuildAs("inspector");u.select("inspector");
    u.setHostOverlay(true);u.setHostOverlayAlpha(0.97);u.setHostPos(12.0,14.0,0.0,0.0);
    u.setHostSize(330.0,PreviewGfx.getHeight()-28.0);
    foreach(action in ["blocked","objects","changes","fit","zoom-in","zoom-out"])u.onClick(action,previewCallback(action,0));
    for(local i=0;i<PreviewReport.objects.len();i+=1)u.onClick("object-"+i,previewCallback("select-object",i));
    for(local i=0;i<PreviewDiagnostics.len();i+=1)u.onClick("diagnostic-"+i,previewCallback("diagnostic",i));
    u.beginBuild();u.beginWindow("地图工具", "root");
    u.text("", "mode");u.text("红：阻挡   蓝：传送   黄：变更   白：当前选择", "legend");
    u.text("", "qa-summary");
    u.end();u.mountBuildAs("top");u.select("top");u.setHostOverlay(true);u.setHostOverlayAlpha(0.94);
    u.setHostPos(360.0,14.0,0.0,0.0);u.setHostSize(PreviewGfx.getWidth()-374.0,96.0);
    u.beginBuild();u.beginWindow("状态", "root");
    u.text("点击格子检查  |  B 阻挡  O 对象  D 变更  R 适配  |  方向键平移", "help");
    u.text("只读预览 · 候选未应用 · 结构可达性不等于剧情条件可达", "boundary");
    u.end();u.mountBuildAs("footer");u.select("footer");u.setHostOverlay(true);u.setHostOverlayAlpha(0.94);
    u.setHostPos(360.0,PreviewGfx.getHeight()-80.0,0.0,0.0);u.setHostSize(PreviewGfx.getWidth()-374.0,66.0);
}
function previewUiRefresh() {
    if(!PreviewInspector)return;
    local u=PreviewUI;u.select("inspector");
    u.setText("summary",PreviewReport.width+" x "+PreviewReport.height+"  |  可走 "+PreviewReport.walkableCount+" 格");
    u.setText("quality",PreviewQA.ok?"QA 通过 · 原生加载 / 寻路 / 拾取":"QA 未通过 · 请检查下方问题");
    u.setText("diff","候选差异："+PreviewCells.len()+" 格 / "+PreviewObjectChanges+" 对象");
    u.setText("blocked",(PreviewState.blocked?"[开] ":"[关] ")+"阻挡标记  B");
    u.setText("objects",(PreviewState.objects?"[开] ":"[关] ")+"对象标记  O");
    u.setText("changes",(PreviewState.changes?"[开] ":"[关] ")+"候选变更  D");
    local x=PreviewState.selectedX;local y=PreviewState.selectedY;local text="点击地图选择格子";
    if(x>=0 && y>=0) {
        text="格子 ("+x+", "+y+")   GID "+PreviewNative.layer.getTile(x,y)+"\n";
        text+=PreviewNative.pathfinder.isWalkable(x,y)?"可通行":"被阻挡";
        foreach(change in PreviewCells)if(change.x==x && change.y==y)
            text+="\n变更 "+RpgcJson.encodeCompact(change.before)+" -> "+RpgcJson.encodeCompact(change.after);
        if(PreviewState.selectedObject>=0) {
            local object=PreviewReport.objects[PreviewState.selectedObject];text+="\n"+object.name+"\n"+object.path;
            if(object.type=="portal")text+="\n落点 "+object.targetMap+" ("+object.targetX+","+object.targetY+")";
        }
    }
    u.setText("selection",text);
    local detail="";
    foreach(d in PreviewDiagnostics) {
        if(detail!="")detail+="\n";
        detail+=d.code+"\n"+Rpgc.get(d,"path","")+"\n"+d.message;
    }
    u.setText("diagnostic-detail",detail);
    u.select("top");local candidate=Rpgc.get(PreviewContext,"candidate",{});
    u.setText("mode",Rpgc.get(candidate,"enabled",false)?"候选地图 / 修改效果预览 · 原文件保持不变":"原始地图 / 导航与对象检查");
    u.setText("qa-summary",PreviewDiagnostics.len()>0?PreviewDiagnostics[0].code+": "+PreviewDiagnostics[0].message:"QA 通过 · 可点击左侧对象或地图格子查看详情");
}
function previewScreen(x,y) {
    local l=PreviewNative.layer;local wx=l.tileToWorldX(x,y)+l.getTileWidth()*0.5;
    local wy=l.tileToWorldY(x,y)+l.getTileHeight()*0.5;
    return {x=PreviewCamera.worldToScreenX(wx,wy,PreviewGfx.getWidth()*1.0,PreviewGfx.getHeight()*1.0),
        y=PreviewCamera.worldToScreenY(wx,wy,PreviewGfx.getWidth()*1.0,PreviewGfx.getHeight()*1.0)};
}
function previewMarker(x,y,size,r,g,b,outline=false) {
    local p=previewScreen(x,y);
    if(p.x<352 || p.x>PreviewGfx.getWidth()-8 || p.y<114 || p.y>PreviewGfx.getHeight()-88)return;
    if(outline) {
        PreviewGfx.drawSolidRect(p.x-size,p.y-size,size*2.0,2.0,r,g,b,1.0);
        PreviewGfx.drawSolidRect(p.x-size,p.y+size-2.0,size*2.0,2.0,r,g,b,1.0);
        PreviewGfx.drawSolidRect(p.x-size,p.y-size,2.0,size*2.0,r,g,b,1.0);
        PreviewGfx.drawSolidRect(p.x+size-2.0,p.y-size,2.0,size*2.0,r,g,b,1.0);
    } else PreviewGfx.drawSolidRect(p.x-size,p.y-size,size*2.0,size*2.0,r,g,b,0.85);
}
function previewKey(key) {
    local down=PreviewKeyboard.isDown(key);local old=Rpgc.get(PreviewKeys,key,false);PreviewKeys.rawset(key,down);return down && !old;
}
eve_init <- function() {
    try {
        PreviewQA=Rpgc.get(PreviewContext,"qa",null);
        if(PreviewQA==null) {
            local check=RpgcMapQA.inspect(MAP_ID_LITERAL);
            PreviewQA={ok=check.ok,diagnostics=check.diagnostics,value={maps=check.value!=0?[check.value]:[]}};
        }
        foreach(report in PreviewQA.value.maps)if(report.id==MAP_ID_LITERAL)PreviewReport=report;
        if(PreviewReport==null)throw "map inspection produced no renderable map";
        PreviewDiagnostics=PreviewQA.diagnostics;
        local diff=Rpgc.get(PreviewContext,"diff",{});PreviewCells=Rpgc.get(diff,"cells",[]);
        PreviewObjectChanges=Rpgc.get(diff,"objects",[]).len();
        PreviewNative=RpgcNavigation.load(MAP_ID_LITERAL);
        PreviewGfx=eve.Graphics();PreviewCamera=eve.Camera2D();PreviewCamera.setAmbient(1.0,1.0,1.0);
        PreviewGfx.setBackgroundColor(0.035,0.045,0.065,1.0);
        // The single-purpose inspector owns its UI; hide SDK debug furniture.
        try {
            if(eve.dev.console.isVisible())eve.dev.console.toggleVisible();
            if(eve.dev.ai.isVisible())eve.dev.ai.toggleVisible();
            if(eve.dev.stats.isVisible())eve.dev.stats.toggleVisible();
        } catch(unavailable) {}

        previewFit();RpgcNavigation.configureLayers(PreviewNative.map,PreviewCamera);
        if(PreviewInspector) {
            PreviewUI=eve.UI();PreviewMouse=eve.Mouse();PreviewKeyboard=eve.Keyboard();
            previewUiBuild();
            if(PreviewReport.objects.len()>0)previewAction("select-object",0);
            previewUiRefresh();
        }
    } catch(error) {PreviewError=""+error;}
};
eve_update <- function(dt) {
    if(PreviewNative==null || PreviewError!="")return;
    PreviewNative.map.update(dt);
    if(!PreviewInspector)return;
    foreach(pair in [["b","blocked"],["o","objects"],["d","changes"],["r","fit"]])
        if(previewKey(pair[0]))previewAction(pair[1],0);
    local dx=0.0;local dy=0.0;
    if(PreviewKeyboard.isDown("left"))dx-=1.0;if(PreviewKeyboard.isDown("right"))dx+=1.0;
    if(PreviewKeyboard.isDown("up"))dy-=1.0;if(PreviewKeyboard.isDown("down"))dy+=1.0;
    if(dx!=0 || dy!=0)PreviewCamera.setPosition(PreviewCamera.getX()+dx*dt*400.0/PreviewState.zoom,PreviewCamera.getY()+dy*dt*400.0/PreviewState.zoom);
    local down=PreviewMouse.isDown(1);local mx=PreviewMouse.getX();local my=PreviewMouse.getY();
    if(down && !PreviewMouseDown && mx>352 && my>114 && my<PreviewGfx.getHeight()-88) {
        local wx=PreviewCamera.screenToWorldX(mx,my,PreviewGfx.getWidth()*1.0,PreviewGfx.getHeight()*1.0);
        local wy=PreviewCamera.screenToWorldY(mx,my,PreviewGfx.getWidth()*1.0,PreviewGfx.getHeight()*1.0);
        local x=PreviewNative.layer.worldToTileX(wx,wy);local y=PreviewNative.layer.worldToTileY(wx,wy);local selected=-1;
        for(local i=0;i<PreviewReport.objects.len();i+=1)if(PreviewReport.objects[i].x==x && PreviewReport.objects[i].y==y)selected=i;
        previewSelect(x,y,selected);
    }
    PreviewMouseDown=down;previewUiRefresh();
};
eve_render <- function() {
    if(PreviewError!="" || PreviewGfx==null)return;
    PreviewGfx.clear();PreviewNative.map.render(PreviewGfx);
    if(PreviewInspector) {
        if(PreviewState.blocked)for(local y=0;y<PreviewReport.height;y+=1)for(local x=0;x<PreviewReport.width;x+=1)
            if(!PreviewReport.walkable[y][x])previewMarker(x,y,2.0,0.92,0.3,0.35);
        if(PreviewState.changes)foreach(cell in PreviewCells)previewMarker(cell.x,cell.y,8.0,1.0,0.8,0.15,true);
        if(PreviewState.objects)foreach(object in PreviewReport.objects) {
            local color=object.type=="portal"?[0.2,0.7,1.0]:(object.type=="spawn"?[0.3,0.9,0.6]:[1.0,0.65,0.2]);
            if(!object.reachable || (object.type=="portal" && !Rpgc.get(object,"landingConnectedToSpawn",true)))color=[1.0,0.2,0.3];
            previewMarker(object.x,object.y,5.0,color[0],color[1],color[2]);
        }
        if(PreviewState.selectedX>=0)previewMarker(PreviewState.selectedX,PreviewState.selectedY,12.0,0.95,0.97,1.0,true);
        PreviewUI.beginFrameAndRender();
    }
    PreviewFrames+=1;
};
function previewStatus() {return RpgcJson.encodeCompact({frames=PreviewFrames,error=PreviewError,qa=PreviewQA,state=PreviewState,
    changedCells=PreviewCells.len(),objectChanges=PreviewObjectChanges,inspector=PreviewInspector});}
'''
