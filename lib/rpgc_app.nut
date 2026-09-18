// EVEngine workflow / rpg-classic — user-facing editor app helpers.
//
// `eve run apps/<id>` mounts this workflow root, then
// opens one editor through the same EditorHost View + ViewModel pair that
// `eve mcp` loads. The three apps are the human entries; MCP remains the
// Agent entry and still restores every editor from `editors/`.

import { Rpgc } from "./rpgc_core.nut"
import { RpgcJson } from "./rpgc_json.nut"
import { RpgcHost } from "./rpgc_host.nut"

export class RpgcApp {
}

RpgcApp.version <- 1

RpgcApp.parentDir <- function (path) {
    local text = "" + path;
    while (text.len() > 1) {
        local last = text.slice(text.len() - 1);
        if (last != "/" && last != "\\") break;
        text = text.slice(0, text.len() - 1);
    }
    local slash = -1;
    local i = text.len() - 1;
    while (i >= 0) {
        local ch = text.slice(i, i + 1);
        if (ch == "/" || ch == "\\") {
            slash = i;
            break;
        }
        i -= 1;
    }
    if (slash <= 0) return text;
    return text.slice(0, slash);
}

// Make `lib/`, `editors/` and `content/` visible when the game root is an
// `apps/<id>` folder. Walk up until those directories exist: one parent is
// `apps/`, which does not contain `mcp.nut`. No-op from the workflow root.
RpgcApp.mountWorkflowRoot <- function () {
    local fs = eve.Filesystem();
    if (fs.readText("lib/rpgc.nut") != "") return Rpgc.ok("workflow");
    local dir = fs.getSource();
    if (dir == null || dir == "") dir = fs.getWorkingDirectory();
    local i = 0;
    while (i < 8) {
        if (fs.isRealDirectory(dir + "/lib") && fs.isRealDirectory(dir + "/editors")) {
            fs.allowMountingForPath(dir);
            if (!fs.mountPath(dir, "/", true)) {
                return Rpgc.fail([Rpgc.error(
                    "app.mount-failed",
                    "cannot mount workflow root from " + dir,
                    dir,
                    "run the app with `eve run apps/<editor>` from this repository")]);
            }
            if (fs.readText("lib/rpgc.nut") == "") {
                return Rpgc.fail([Rpgc.error(
                    "app.mount-empty",
                    "mounted " + dir + " but lib/rpgc.nut is still missing",
                    dir,
                    "")]);
            }
            return Rpgc.ok(dir);
        }
        local parent = this.parentDir(dir);
        if (parent == dir || parent == "") break;
        dir = parent;
        i += 1;
    }
    return Rpgc.fail([Rpgc.error(
        "app.mount-not-found",
        "cannot find workflow root (lib/ + editors/) above " + fs.getSource(),
        fs.getSource(),
        "")]);
}

// Compile editors/<id>.vm.nut and apply editors/<id>.editor.json.
RpgcApp.openEditor <- function (id) {
    if (!("host" in eve)) {
        return Rpgc.fail([Rpgc.error(
            "app.no-host",
            "eve.host is not available",
            id,
            "set config.editorHost=true so eve run starts the editor host")]);
    }
    local fs = eve.Filesystem();
    local viewPath = "editors/" + id + ".editor.json";
    local vmPath = "editors/" + id + ".vm.nut";
    local viewText = fs.readText(viewPath);
    if (viewText == "") {
        return Rpgc.fail([Rpgc.error(
            "app.missing-view",
            "missing editor view " + viewPath,
            viewPath,
            "mount the workflow root before opening an editor")]);
    }
    local parsed = RpgcJson.parse(viewText);
    if (!parsed.ok) return parsed;
    local vmName = Rpgc.asString(Rpgc.get(parsed.value, "vm", ""));
    if (vmName == "") {
        return Rpgc.fail([Rpgc.error(
            "app.missing-vm-name",
            "editor view has no vm field",
            viewPath,
            "")]);
    }
    local vmText = fs.readText(vmPath);
    if (vmText == "") {
        return Rpgc.fail([Rpgc.error(
            "app.missing-vm",
            "missing editor ViewModel " + vmPath,
            vmPath,
            "")]);
    }
    local registered = "error: registerVM did not run";
    try {
        registered = eve.host.registerVM(vmName, vmText, "game:/" + vmPath);
    } catch (e) {
        registered = "error: registerVM threw " + e;
    }
    if (registered != "ok") {
        local stacked = "";
        try { if ("lastScriptError" in eve) stacked = eve.lastScriptError(); } catch (e) {}
        if ("log" in eve) eve.log("error", "rpgc: registerVM " + vmPath + ": " + registered + " | " + stacked);
        return Rpgc.fail([Rpgc.error(
            "app.register-vm",
            stacked != "" ? stacked : ("" + registered),
            vmPath,
            "")]);
    }
    local applied = eve.host.applyEditor(viewText);
    if (typeof applied == "string" && applied.len() >= 6 && applied.slice(0, 6) == "error:") {
        return Rpgc.fail([Rpgc.error(
            "app.apply-editor",
            applied,
            viewPath,
            "")]);
    }
    RpgcHost.setActive(id);
    if ("log" in eve) eve.log("info", "rpgc: editor open " + id);
    return Rpgc.ok(id);
}
