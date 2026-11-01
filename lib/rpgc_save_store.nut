// Native user-directory persistence. There is deliberately no non-atomic fallback.
import { Rpgc } from "game:/lib/rpgc_core.nut"
import { RpgcJson } from "game:/lib/rpgc_json.nut"
import { RpgcSave } from "game:/lib/rpgc_save.nut"

export class RpgcSaveStore {}
RpgcSaveStore.version <- 1
RpgcSaveStore.identity <- "rpg-classic-player-v1"
RpgcSaveStore.ready <- false
RpgcSaveStore.directory <- ""
RpgcSaveStore.failure <- function(code,message) {
    return Rpgc.fail([Rpgc.error("save-store."+code,message,"$","")]);
}
RpgcSaveStore.initialize <- function() {
    try {
        local fs=eve.Filesystem();
        if(this.ready && fs.getIdentity()==this.identity && fs.getSaveDirectory()==this.directory)return Rpgc.ok({directory=this.directory,atomic=true});
        this.ready <- false;
        if(!fs.setIdentity(this.identity,false) || !fs.setupWriteDirectory())return this.failure("unavailable","native user save directory is unavailable");
        local directory=fs.getSaveDirectory();local working=fs.getWorkingDirectory();local source=fs.getSource();
        if(directory=="" || directory==working || directory.find(working+"/")==0 || (source!="" && (directory==source || directory.find(source+"/")==0)))
            return this.failure("unsafe-directory","refusing to store player saves inside the project/source directory");
        local name="rpgc-atomic-capability.probe";
        if(fs.writeTextAtomic(name,"first")!=1 || fs.writeTextAtomic(name,"second")!=1 || fs.readText(name)!="second" || fs.getRealDirectory(name)!=directory)
            return this.failure("atomic-unavailable","native atomic replacement/readback probe failed; no fallback write was attempted");
        fs.remove(name);
        this.directory <- directory;this.ready <- true;
        return Rpgc.ok({directory=directory,atomic=true});
    } catch(error) {return this.failure("atomic-unavailable","native atomic save API unavailable: "+error);}
}
RpgcSaveStore.slotName <- function(slot) {
    if(!Rpgc.validId(slot) || slot=="." || slot.find("..")!=null)return this.failure("slot","slot must be a stable id without parent traversal");
    return Rpgc.ok("player-"+slot+".json");
}
RpgcSaveStore.readFile <- function(name) {
    try {
        local fs=eve.Filesystem();
        if(fs.getDirectoryItems("").find(name)==null)return Rpgc.ok({exists=false,text=""});
        local source=fs.getRealDirectory(name);
        if(source!=this.directory)return this.failure("source","save file resolved outside the configured user directory");
        return Rpgc.ok({exists=true,text=fs.readText(name)});
    } catch(error) {return this.failure("read","could not read player save: "+error);}
}
RpgcSaveStore.decode <- function(text) {
    local parsed=RpgcJson.parse(text);if(!parsed.ok)return parsed;
    local restored=RpgcSave.restore(parsed.value);if(!restored.ok)return restored;
    return Rpgc.ok({snapshot=parsed.value,candidate=restored.value});
}
RpgcSaveStore.writeVerified <- function(name,text) {
    try {
        if(eve.Filesystem().writeTextAtomic(name,text)!=1)return this.failure("atomic-write","native atomic replacement failed for "+name);
        local read=this.readFile(name);if(!read.ok)return read;
        if(!read.value.exists || read.value.text!=text)return this.failure("readback","atomic save readback differs for "+name);
        return Rpgc.ok(true);
    } catch(error) {return this.failure("atomic-write","native atomic replacement failed: "+error);}
}
RpgcSaveStore.save <- function(snapshot,slot="slot1") {
    // Invalid candidates cannot overwrite either existing generation.
    local restored=RpgcSave.restore(snapshot);if(!restored.ok)return restored;
    local name=this.slotName(slot);if(!name.ok)return name;
    local initialized=this.initialize();if(!initialized.ok)return initialized;
    local primary=this.readFile(name.value);if(!primary.ok)return primary;
    local backupName=name.value+".backup";
    if(primary.value.exists) {
        local old=this.decode(primary.value.text);
        if(old.ok) {
            local backed=this.writeVerified(backupName,primary.value.text);if(!backed.ok)return backed;
        } else {
            // Do not replace the last recoverable generation with corrupt data.
            local backup=this.readFile(backupName);if(!backup.ok)return backup;
            if(!backup.value.exists || !this.decode(backup.value.text).ok)
                return this.failure("previous-invalid","existing primary and backup are not valid; preserve them and use another slot");
        }
    } else {
        local backup=this.readFile(backupName);if(!backup.ok)return backup;
        if(backup.value.exists && !this.decode(backup.value.text).ok)return this.failure("previous-invalid","existing backup is invalid; preserving it instead of replacing the slot");
    }
    local written=this.writeVerified(name.value,RpgcJson.encodeCompact(snapshot));if(!written.ok)return written;
    return Rpgc.ok({slot=slot,directory=this.directory,primary=name.value,backup=backupName,persisted=true});
}
RpgcSaveStore.load <- function(slot="slot1") {
    local name=this.slotName(slot);if(!name.ok)return name;
    local initialized=this.initialize();if(!initialized.ok)return initialized;
    local primary=this.readFile(name.value);if(!primary.ok)return primary;
    local primaryFailure=[];
    if(primary.value.exists) {
        local decoded=this.decode(primary.value.text);
        if(decoded.ok) {decoded.value.source<-"primary";decoded.value.directory<-this.directory;decoded.value.slot<-slot;return decoded;}
        primaryFailure=decoded.diagnostics;
    }
    local backup=this.readFile(name.value+".backup");if(!backup.ok)return backup;
    if(backup.value.exists) {
        local decoded=this.decode(backup.value.text);
        if(decoded.ok) {
            decoded.value.source<-"backup";decoded.value.directory<-this.directory;decoded.value.slot<-slot;
            decoded.diagnostics.append(Rpgc.warn("save-store.backup-restored","primary missing/invalid; loaded the previous valid generation without overwriting either file",name.value,""));
            return decoded;
        }
        foreach(d in decoded.diagnostics)primaryFailure.append(d);
    }
    primaryFailure.append(Rpgc.error("save-store.no-valid-generation","no valid primary or backup player save",name.value,""));
    return Rpgc.fail(primaryFailure);
}
