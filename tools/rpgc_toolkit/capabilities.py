"""Operation-based SDK probes. Headless results do not claim GPU/audio rendering."""
import hashlib
from pathlib import Path
from .runtime import run_headless

SOURCE = '''local checks=[];
local probe=function(name,action){
    try {local value=action();checks.append({id=name,supported=value,scope="native-no-window",reason=value?"operation verified":"operation did not produce expected result"});}
    catch(e){checks.append({id=name,supported=false,scope="native-no-window",reason=""+e});}
};
probe("camera-position",function(){local c=eve.Camera2D();c.setPosition(12.0,34.0);return c.getX()==12.0 && c.getY()==34.0;});
probe("sprite-clip-clock",function(){
    local a=eve.Animation();local sheet=a.newSpriteSheet();sheet.setGrid(4,2,32,48,0,0,0,0);
    local clip=a.newSpriteClip("capability-probe");clip.addRange(0,1,10.0);clip.setLoop(false);
    local player=a.newSpriteAnim();player.setSheet(sheet);player.play(clip);player.update(0.3);
    return sheet.getFrameCount()==8 && player.isFinished();
});
probe("map-contract-load",function(){local m=eve.Map();local text=eve.Filesystem().readText("data/world-object-contract.json");
    local result=m.loadFromFileWithObjectContract("content/maps/village-outskirts.json",text);return result.ok && m.getLayer(0)!=null;});
probe("schema-gate",function(){return RpgcValidate.validateFile("item","content/items/potion.heal.json").ok;});
local ok=true;foreach(check in checks) if(!check.supported)ok=false;
RpgcToolkitResult <- RpgcJson.encodeCompact({ok=ok,fixtureVersion=1,checks=checks,
    rendered=false,audioPlaybackVerified=false,saveDurabilityVerified=false});
'''


def probe_capabilities(binary,root,timeout=120):
    report=run_headless(binary,root,SOURCE,timeout)
    report['sdkSha256']=hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    return report
