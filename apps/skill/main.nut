// User entry for the skill editor.
RpgcEditorId <- "skill";

function rpgcParentDir(path) {
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
        if (ch == "/" || ch == "\\" ) {
            slash = i;
            break;
        }
        i -= 1;
    }
    if (slash < 0) return text;
    if (slash == 0) return text.slice(0, 1);
    return text.slice(0, slash);
}

function rpgcMountWorkflow() {
    if (!has_module("fs")) throw "rpgc: filesystem module is not loaded";
    if (fs.readText("mcp.nut") != "" && fs.readText("lib/rpgc.nut") != "") return;
    local starts = [fs.getWorkingDirectory(), fs.getSource()];
    local seen = {};
    foreach (start in starts) {
        local dir = start;
        if (dir == null || dir == "" || (dir in seen)) continue;
        local i = 0;
        while (i < 8) {
            seen[dir] <- true;
            if (fs.isRealDirectory(dir + "/lib") && fs.isRealDirectory(dir + "/editors")) {
                fs.allowMountingForPath(dir);
                if (!fs.mountPath(dir, "/", true))
                    throw "rpgc: cannot mount workflow root from " + dir;
                if (fs.readText("mcp.nut") == "" || fs.readText("lib/rpgc.nut") == "")
                    throw "rpgc: mounted " + dir + " but mcp.nut / lib/rpgc.nut are still missing";
                print("[rpgc] mounted workflow root " + dir + "\n");
                return;
            }
            local parent = rpgcParentDir(dir);
            if (parent == dir || parent == "") break;
            dir = parent;
            i += 1;
        }
    }
    throw "rpgc: cannot find workflow root (lib/ + editors/) above "
        + fs.getWorkingDirectory() + " (source=" + fs.getSource() + ")";
}

eve_init = function () {
    rpgcMountWorkflow();
    RpgcDeferBootstrap <- true;
    // `RpgcEditorId` is published on the root above. This script is `dofile`d
    // by load.nut, so it has no module environment and cannot `import` the
    // library; mcp.nut is compiled by the host and opens the editor for us.
    local mcp = fs.readText("mcp.nut");
    if (mcp == null || mcp == "")
        throw "rpgc: mcp.nut is empty after mounting the workflow root";
    local loaded = eve.host.runScript(mcp, "game:/mcp.nut");
    if (loaded != "ok") {
        local stacked = "";
        try { if ("lastScriptError" in eve) stacked = eve.lastScriptError(); } catch (e) {}
        if ("log" in eve) eve.log("error", "rpgc: mcp.nut: " + loaded + " | " + stacked);
        throw loaded;
    }
};

eve_update = function (dt) {};
eve_render = function () {};
