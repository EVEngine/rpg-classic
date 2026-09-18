// EVEngine workflow / rpg-classic 鈥?strict JSON codec.
//
// The engine's own JSON reader (`eve.DataModule().decodeJson`) produces an
// opaque `JsonDocument` with no script-side traversal, and the engine's map /
// rpg loaders only accept raw text. Project toolchains therefore need a real
// JSON value model in script. This module is that model:
//
//   parse(text)      -> { ok, value, diagnostics }   (value: table/array/scalar)
//   encode(value)    -> canonical, diff-friendly text
//   encodeCompact()  -> canonical single-line text
//   clone / equal / fingerprint
//
// Strictness is the point: an AI may write any text it likes, and the codec
// must refuse everything the engine would silently misinterpret.
// Rejected: duplicate object keys, trailing commas, comments, `NaN`/`Infinity`,
// bare control characters in strings, invalid or unterminated escapes, leading
// zeroes, `+` signs, a `-` without digits, exponent overflow, trailing garbage.
//
// Canonical encoding is deterministic: object keys are sorted byte-wise, floats
// use the shortest `%g` form that reads back to the identical value, and arrays
// of scalars wrap deterministically. Two equal documents always encode to the
// same bytes, so fingerprints are stable across machines.

export class RpgcJson {
}

RpgcJson.version <- 1
RpgcJson.maxDepth <- 64

// ------------------------------------------------------------------ parse

RpgcJson.parse <- function (text) {
    local st = {};
    st.text <- text;
    st.pos <- 0;
    st.len <- text.len();
    st.depth <- 0;
    st.diags <- [];
    // A UTF-8 byte-order mark is what Windows editors and PowerShell's
    // `Set-Content -Encoding utf8` put in front of a file. Those three bytes
    // are not JSON whitespace, so without this check the first thing an
    // operator sees is "unexpected character '\xef' at offset 0".
    if (text.len() >= 3 && text.slice(0, 3) == "\xEF\xBB\xBF") {
        this._pushDiag(st, "json.bom",
            "document starts with a UTF-8 byte-order mark", "$",
            "save the file as UTF-8 without BOM; the first byte must be '{' or '['");
        return this._res(false, 0, st.diags);
    }
    this._ws(st);
    if (st.pos >= st.len) {
        this._pushDiag(st, "json.empty", "document is empty", "$");
        return this._res(false, 0, st.diags);
    }
    local value = this._value(st, "$");
    if (st.diags.len() > 0) return this._res(false, 0, st.diags);
    this._ws(st);
    if (st.pos < st.len) {
        this._pushDiag(st, "json.trailing",
            "unexpected trailing content at offset " + st.pos, "$");
        return this._res(false, 0, st.diags);
    }
    return this._res(true, value, []);
}

RpgcJson._res <- function (ok, value, diags) {
    local out = {};
    out.ok <- ok;
    out.value <- value;
    out.diagnostics <- diags;
    return out;
}

RpgcJson._pushDiag <- function (st, code, message, path, hint = "") {
    local d = {};
    d.code <- code;
    d.severity <- "error";
    d.message <- message;
    d.path <- path;
    if (hint != "") d.hint <- hint;
    st.diags.append(d);
}

RpgcJson._isWs <- function (c) {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

RpgcJson._ws <- function (st) {
    while (st.pos < st.len && this._isWs(st.text[st.pos])) st.pos += 1;
}

RpgcJson._value <- function (st, path) {
    if (st.depth > this.maxDepth) {
        this._pushDiag(st, "json.depth", "nesting exceeds " + this.maxDepth, path);
        return 0;
    }
    this._ws(st);
    if (st.pos >= st.len) {
        this._pushDiag(st, "json.eof", "unexpected end of input", path);
        return 0;
    }
    local c = st.text[st.pos];
    if (c == 123) return this._object(st, path);      // {
    if (c == 91) return this._array(st, path);        // [
    if (c == 34) return this._string(st, path);       // "
    if (c == 116) return this._literal(st, path, "true", true);
    if (c == 102) return this._literal(st, path, "false", false);
    if (c == 110) return this._literal(st, path, "null", 0);
    if (c == 45 || (c >= 48 && c <= 57)) return this._number(st, path);
    this._pushDiag(st, "json.unexpected",
        "unexpected character '" + this._ch(c) + "' at offset " + st.pos, path);
    return 0;
}

RpgcJson._literal <- function (st, path, word, value) {
    if (st.text.len() < st.pos + word.len() ||
        st.text.slice(st.pos, st.pos + word.len()) != word) {
        this._pushDiag(st, "json.literal",
            "expected '" + word + "' at offset " + st.pos, path);
        return 0;
    }
    st.pos += word.len();
    return value;
}

RpgcJson._object <- function (st, path) {
    st.pos += 1;
    st.depth += 1;
    local out = {};
    this._ws(st);
    if (st.pos < st.len && st.text[st.pos] == 125) {
        st.pos += 1;
        st.depth -= 1;
        return out;
    }
    while (true) {
        this._ws(st);
        if (st.pos >= st.len || st.text[st.pos] != 34) {
            this._pushDiag(st, "json.key", "expected a string key at offset " + st.pos, path);
            st.depth -= 1;
            return 0;
        }
        local key = this._string(st, path);
        if (st.diags.len() > 0) {
            st.depth -= 1;
            return 0;
        }
        this._ws(st);
        if (st.pos >= st.len || st.text[st.pos] != 58) {
            this._pushDiag(st, "json.colon", "expected ':' after key '" + key + "'",
                path + "/" + key);
            st.depth -= 1;
            return 0;
        }
        st.pos += 1;
        if (out.rawin(key)) {
            this._pushDiag(st, "json.duplicate-key", "duplicate key '" + key + "'",
                path + "/" + key);
            st.depth -= 1;
            return 0;
        }
        local value = this._value(st, path + "/" + key);
        if (st.diags.len() > 0) {
            st.depth -= 1;
            return 0;
        }
        out.rawset(key, value);
        this._ws(st);
        if (st.pos >= st.len) {
            this._pushDiag(st, "json.eof", "unexpected end of input inside object", path);
            st.depth -= 1;
            return 0;
        }
        local c = st.text[st.pos];
        if (c == 44) {
            st.pos += 1;
            this._ws(st);
            if (st.pos < st.len && st.text[st.pos] == 125) {
                this._pushDiag(st, "json.trailing-comma",
                    "trailing comma before '}' at offset " + st.pos, path);
                st.depth -= 1;
                return 0;
            }
            continue;
        }
        if (c == 125) {
            st.pos += 1;
            st.depth -= 1;
            return out;
        }
        this._pushDiag(st, "json.separator",
            "expected ',' or '}' at offset " + st.pos, path);
        st.depth -= 1;
        return 0;
    }
}

RpgcJson._array <- function (st, path) {
    st.pos += 1;
    st.depth += 1;
    local out = [];
    this._ws(st);
    if (st.pos < st.len && st.text[st.pos] == 93) {
        st.pos += 1;
        st.depth -= 1;
        return out;
    }
    while (true) {
        local index = out.len();
        local value = this._value(st, path + "/" + index);
        if (st.diags.len() > 0) {
            st.depth -= 1;
            return 0;
        }
        out.append(value);
        this._ws(st);
        if (st.pos >= st.len) {
            this._pushDiag(st, "json.eof", "unexpected end of input inside array", path);
            st.depth -= 1;
            return 0;
        }
        local c = st.text[st.pos];
        if (c == 44) {
            st.pos += 1;
            this._ws(st);
            if (st.pos < st.len && st.text[st.pos] == 93) {
                this._pushDiag(st, "json.trailing-comma",
                    "trailing comma before ']' at offset " + st.pos, path);
                st.depth -= 1;
                return 0;
            }
            continue;
        }
        if (c == 93) {
            st.pos += 1;
            st.depth -= 1;
            return out;
        }
        this._pushDiag(st, "json.separator",
            "expected ',' or ']' at offset " + st.pos, path);
        st.depth -= 1;
        return 0;
    }
}

RpgcJson._hex <- function (c) {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 97 && c <= 102) return c - 87;
    if (c >= 65 && c <= 70) return c - 55;
    return -1;
}

RpgcJson._string <- function (st, path) {
    st.pos += 1;  // opening quote
    local out = "";
    while (true) {
        if (st.pos >= st.len) {
            this._pushDiag(st, "json.string", "unterminated string", path);
            return "";
        }
        // Mask to an unsigned byte: a `string[index]` read of a byte >= 0x80
        // yields a NEGATIVE Squirrel integer, which would make every UTF-8
        // continuation byte look like an unescaped control character and
        // reject valid JSON. Every other byte comparison in this file does
        // the same mask.
        local c = st.text[st.pos] & 0xFF;
        if (c == 34) {
            st.pos += 1;
            return out;
        }
        if (c == 92) {  // backslash
            st.pos += 1;
            if (st.pos >= st.len) {
                this._pushDiag(st, "json.escape", "unterminated escape sequence", path);
                return "";
            }
            local e = st.text[st.pos];
            st.pos += 1;
            if (e == 34) out += "\"";
            else if (e == 92) out += "\\";
            else if (e == 47) out += "/";
            else if (e == 98) out += this._byte(8);
            else if (e == 102) out += this._byte(12);
            else if (e == 110) out += this._byte(10);
            else if (e == 114) out += this._byte(13);
            else if (e == 116) out += this._byte(9);
            else if (e == 117) {
                local unit = this._u4(st, path);
                if (unit < 0) return "";
                if (unit >= 0xD800 && unit <= 0xDBFF) {
                    // High surrogate: a low surrogate must follow.
                    if (st.pos + 1 < st.len && st.text[st.pos] == 92 &&
                        st.text[st.pos + 1] == 117) {
                        st.pos += 2;
                        local low = this._u4(st, path);
                        if (low < 0) return "";
                        if (low < 0xDC00 || low > 0xDFFF) {
                            this._pushDiag(st, "json.escape",
                                "high surrogate not followed by a low surrogate", path);
                            return "";
                        }
                        out += this._utf8(0x10000 + ((unit - 0xD800) << 10) +
                                          (low - 0xDC00));
                    } else {
                        this._pushDiag(st, "json.escape",
                            "lone high surrogate escape", path);
                        return "";
                    }
                } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
                    this._pushDiag(st, "json.escape", "lone low surrogate escape", path);
                    return "";
                } else {
                    out += this._utf8(unit);
                }
            } else {
                this._pushDiag(st, "json.escape",
                    "unsupported escape '\\" + this._ch(e) + "'", path);
                return "";
            }
            continue;
        }
        if ((c & 0xFF) < 32) {
            this._pushDiag(st, "json.control",
                "unescaped control character at offset " + st.pos, path);
            return "";
        }
        // Copy a run of literal bytes in one slice for speed.
        local start = st.pos;
        while (st.pos < st.len) {
            local b = st.text[st.pos] & 0xFF;
            if (b == 34 || b == 92 || b < 32) break;
            st.pos += 1;
        }
        out += st.text.slice(start, st.pos);
    }
}

RpgcJson._u4 <- function (st, path) {
    if (st.pos + 4 > st.len) {
        this._pushDiag(st, "json.escape", "truncated \\u escape", path);
        return -1;
    }
    local value = 0;
    for (local i = 0; i < 4; i += 1) {
        local d = this._hex(st.text[st.pos + i]);
        if (d < 0) {
            this._pushDiag(st, "json.escape", "invalid hex digit in \\u escape", path);
            return -1;
        }
        value = value * 16 + d;
    }
    st.pos += 4;
    return value;
}

RpgcJson._byte <- function (code) {
    return format("%c", code);
}

RpgcJson._ch <- function (code) {
    local byte = code & 0xFF;
    if (byte < 32 || byte > 126) return "\\x" + format("%02x", byte);
    return this._byte(code);
}

RpgcJson._utf8 <- function (cp) {
    if (cp < 0x80) return this._byte(cp);
    if (cp < 0x800) {
        return this._byte(0xC0 | (cp >> 6)) + this._byte(0x80 | (cp & 0x3F));
    }
    if (cp < 0x10000) {
        return this._byte(0xE0 | (cp >> 12)) +
               this._byte(0x80 | ((cp >> 6) & 0x3F)) +
               this._byte(0x80 | (cp & 0x3F));
    }
    return this._byte(0xF0 | (cp >> 18)) +
           this._byte(0x80 | ((cp >> 12) & 0x3F)) +
           this._byte(0x80 | ((cp >> 6) & 0x3F)) +
           this._byte(0x80 | (cp & 0x3F));
}

// JSON numbers must be finite and fit Squirrel's 32-bit float. The engine
// rejects non-finite numbers on every schema, so accepting them here would
// only move the failure later.
RpgcJson._number <- function (st, path) {
    local start = st.pos;
    if (st.text[st.pos] == 45) st.pos += 1;
    if (st.pos >= st.len) {
        this._pushDiag(st, "json.number", "truncated number", path);
        return 0;
    }
    local digits = 0;
    if (st.text[st.pos] == 48) {
        st.pos += 1;
        digits = 1;
    } else if (st.text[st.pos] >= 49 && st.text[st.pos] <= 57) {
        while (st.pos < st.len && st.text[st.pos] >= 48 && st.text[st.pos] <= 57) {
            st.pos += 1;
            digits += 1;
        }
    } else {
        this._pushDiag(st, "json.number", "expected a digit at offset " + st.pos, path);
        return 0;
    }
    local integral = true;
    if (st.pos < st.len && st.text[st.pos] == 46) {
        integral = false;
        st.pos += 1;
        local frac = 0;
        while (st.pos < st.len && st.text[st.pos] >= 48 && st.text[st.pos] <= 57) {
            st.pos += 1;
            frac += 1;
        }
        if (frac == 0) {
            this._pushDiag(st, "json.number", "expected digits after '.'", path);
            return 0;
        }
    }
    if (st.pos < st.len && (st.text[st.pos] == 101 || st.text[st.pos] == 69)) {
        integral = false;
        st.pos += 1;
        if (st.pos < st.len && (st.text[st.pos] == 43 || st.text[st.pos] == 45)) st.pos += 1;
        local exp = 0;
        while (st.pos < st.len && st.text[st.pos] >= 48 && st.text[st.pos] <= 57) {
            st.pos += 1;
            exp += 1;
        }
        if (exp == 0) {
            this._pushDiag(st, "json.number", "expected digits in exponent", path);
            return 0;
        }
        if (exp > 3) {
            this._pushDiag(st, "json.number", "exponent out of range", path);
            return 0;
        }
    }
    local raw = st.text.slice(start, st.pos);
    if (integral) {
        local asInt = raw.tointeger();
        // Squirrel integers are 32-bit; documents stay well inside that.
        if (asInt >= -2147483647 && asInt <= 2147483647) return asInt;
    }
    return raw.tofloat();
}

// ----------------------------------------------------------------- encode

RpgcJson.encode <- function (value) {
    local out = [];
    this._emit(value, 0, out);
    return this._join(out);
}

RpgcJson.encodeCompact <- function (value) {
    local out = [];
    this._emitCompact(value, out);
    return this._join(out);
}

RpgcJson._join <- function (parts) {
    local text = "";
    foreach (part in parts) text += part;
    return text;
}

RpgcJson._emitCompact <- function (value, out) {
    local t = typeof value;
    if (value == null) {
        out.append("null");
    } else if (t == "bool") {
        out.append(value ? "true" : "false");
    } else if (t == "integer") {
        out.append(value.tostring());
    } else if (t == "float") {
        out.append(this._floatText(value));
    } else if (t == "string") {
        out.append(this._quote(value));
    } else if (t == "array") {
        out.append("[");
        for (local i = 0; i < value.len(); i += 1) {
            if (i > 0) out.append(",");
            this._emitCompact(value[i], out);
        }
        out.append("]");
    } else if (t == "table") {
        out.append("{");
        local keys = this._sortedKeys(value);
        for (local i = 0; i < keys.len(); i += 1) {
            if (i > 0) out.append(",");
            out.append(this._quote(keys[i]));
            out.append(":");
            this._emitCompact(value.rawget(keys[i]), out);
        }
        out.append("}");
    } else {
        out.append("null");  // closures/instances are not document data
    }
}

RpgcJson._emit <- function (value, indent, out) {
    local t = typeof value;
    if (t == "array") {
        this._emitArray(value, indent, out);
        return;
    }
    if (t == "table") {
        this._emitObject(value, indent, out);
        return;
    }
    local tmp = [];
    this._emitCompact(value, tmp);
    out.append(tmp[0]);
}

RpgcJson._pad <- function (indent) {
    local s = "";
    for (local i = 0; i < indent; i += 1) s += "  ";
    return s;
}

RpgcJson._isScalar <- function (v) {
    local t = typeof v;
    return t != "array" && t != "table";
}

RpgcJson._emitArray <- function (value, indent, out) {
    if (value.len() == 0) {
        out.append("[]");
        return;
    }
    local scalars = true;
    for (local i = 0; i < value.len(); i += 1) {
        if (!this._isScalar(value[i])) {
            scalars = false;
            break;
        }
    }
    if (scalars) {
        local parts = [];
        for (local i = 0; i < value.len(); i += 1) {
            local tmp = [];
            this._emitCompact(value[i], tmp);
            parts.append(tmp[0]);
        }
        local line = this._join(parts);
        if (value.len() <= 16 && line.len() <= 96) {
            out.append("[");
            for (local i = 0; i < parts.len(); i += 1) {
                if (i > 0) out.append(", ");
                out.append(parts[i]);
            }
            out.append("]");
            return;
        }
        // Long numeric tables (tile GID grids) wrap at 16 per line so the
        // file stays diffable instead of becoming one enormous line.
        out.append("[\n");
        local inner = indent + 1;
        for (local i = 0; i < parts.len(); i += 1) {
            if (i % 16 == 0) out.append(this._pad(inner));
            out.append(parts[i]);
            if (i + 1 < parts.len()) out.append(",");
            if (i % 16 == 15 || i + 1 == parts.len()) {
                out.append("\n");
            } else {
                out.append(" ");
            }
        }
        out.append(this._pad(indent));
        out.append("]");
        return;
    }
    out.append("[\n");
    for (local i = 0; i < value.len(); i += 1) {
        out.append(this._pad(indent + 1));
        this._emit(value[i], indent + 1, out);
        if (i + 1 < value.len()) out.append(",");
        out.append("\n");
    }
    out.append(this._pad(indent));
    out.append("]");
}

RpgcJson._emitObject <- function (value, indent, out) {
    local keys = this._sortedKeys(value);
    if (keys.len() == 0) {
        out.append("{}");
        return;
    }
    out.append("{\n");
    for (local i = 0; i < keys.len(); i += 1) {
        out.append(this._pad(indent + 1));
        out.append(this._quote(keys[i]));
        out.append(": ");
        this._emit(value.rawget(keys[i]), indent + 1, out);
        if (i + 1 < keys.len()) out.append(",");
        out.append("\n");
    }
    out.append(this._pad(indent));
    out.append("}");
}

RpgcJson._sortedKeys <- function (value) {
    local keys = value.keys();
    keys.sort(function (a, b) { return a < b ? -1 : (a > b ? 1 : 0); });
    return keys;
}

// Shortest `%g` form that reads back to the identical float. Keeps 0.1 as
// "0.1" instead of the float32 truth "0.100000001" without losing exactness.
RpgcJson._floatText <- function (value) {
    foreach (digits in [6, 7, 8, 9]) {
        local text = format("%." + digits + "g", value);
        local round = 0.0;
        try {
            round = text.tofloat();
        } catch (e) {
            continue;
        }
        if (round == value) {
            if (!this._looksFloat(text)) text += ".0";
            return text;
        }
    }
    local text = format("%.9g", value);
    if (!this._looksFloat(text)) text += ".0";
    return text;
}

RpgcJson._looksFloat <- function (text) {
    return text.find(".") >= 0 || text.find("e") >= 0 || text.find("E") >= 0;
}

RpgcJson._quote <- function (text) {
    local out = ["\""];
    local start = 0;
    for (local i = 0; i < text.len(); i += 1) {
        local c = text[i] & 0xFF;
        local escape = "";
        if (c == 34) escape = "\\\"";
        else if (c == 92) escape = "\\\\";
        else if (c == 10) escape = "\\n";
        else if (c == 13) escape = "\\r";
        else if (c == 9) escape = "\\t";
        else if (c < 32) escape = "\\u" + format("%04x", c);
        if (escape == "") continue;
        if (i > start) out.append(text.slice(start, i));
        out.append(escape);
        start = i + 1;
    }
    if (text.len() > start) out.append(text.slice(start, text.len()));
    out.append("\"");
    return this._join(out);
}

// ------------------------------------------------------------------ tools

// Deep copy. Named `deepCopy` because `clone` is a Squirrel keyword and
// cannot appear as a member name at the call site.
RpgcJson.deepCopy <- function (value) {
    local t = typeof value;
    if (t == "array") {
        local out = [];
        for (local i = 0; i < value.len(); i += 1) out.append(this.deepCopy(value[i]));
        return out;
    }
    if (t == "table") {
        local out = {};
        foreach (k, v in value) out.rawset(k, this.deepCopy(v));
        return out;
    }
    return value;
}

RpgcJson.equal <- function (a, b) {
    local ta = typeof a;
    if (ta != typeof b) return false;
    if (ta == "array") {
        if (a.len() != b.len()) return false;
        for (local i = 0; i < a.len(); i += 1) {
            if (!this.equal(a[i], b[i])) return false;
        }
        return true;
    }
    if (ta == "table") {
        local ka = this._sortedKeys(a);
        local kb = this._sortedKeys(b);
        if (ka.len() != kb.len()) return false;
        for (local i = 0; i < ka.len(); i += 1) {
            if (ka[i] != kb[i]) return false;
            if (!this.equal(a.rawget(ka[i]), b.rawget(kb[i]))) return false;
        }
        return true;
    }
    return a == b;
}

RpgcJson.typeName <- function (value) {
    local t = typeof value;
    if (t == "bool") return "bool";
    if (t == "integer") return "int";
    if (t == "float") return "number";
    if (t == "string") return "string";
    if (t == "array") return "array";
    if (t == "table") return "object";
    return "unsupported";
}

// A small rolling hash over the canonical compact text: stable across
// machines and good enough to detect "this document changed under you".
//
// Deliberately arithmetic-only. Squirrel's integers are 32-bit here, so an
// FNV-1a constant like 2166136261 or a mask like 0xFFFFFFFF does not fit:
// the expression silently promotes to float and the next `^`/`&` then has a
// float operand. Reducing modulo 65521 after every step keeps the largest
// intermediate at 31 * 65520 + 255, far inside the integer range.
RpgcJson.fingerprint <- function (value) {
    return this.hashText(this.encodeCompact(value));
}

// Same hash, applied to text that is already in hand. Document revisions
// use this so a read does not have to re-encode the document: encoding is
// quadratic in the number of emitted chunks, and it dominated host
// start-up when every read went through `fingerprint`.
RpgcJson.hashText <- function (text) {
    local hash = 7;
    for (local i = 0; i < text.len(); i += 1) {
        hash = (hash * 31 + (text[i] & 0xFF)) % 65521;
    }
    return format("%08x", hash);
}
