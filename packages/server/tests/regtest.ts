#!/usr/bin/env bun
/**
 * RegTest: IF regression tester for wasiglk interpreters.
 *
 * Port of regtest.py (Andrew Plotkin, public domain) plus run-regtest.sh
 * runner logic, combined into a single Bun/TypeScript script.
 *
 * Usage:
 *   bun regtest.ts                          # Run all tests
 *   bun regtest.ts advent.ulx               # Run tests for a specific game
 *   bun regtest.ts advent.ulx prologue      # Run a specific test section
 *
 * Environment:
 *   INTERP_DIR  - Path to interpreter binaries (default: ../zig-out/bin)
 *   PLATFORM    - 'native' or 'wasm' (default: native)
 *   TIMEOUT     - Timeout in seconds (default: 30)
 */

import {readFileSync, readdirSync, existsSync} from "fs";
import {join, dirname, basename} from "path";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface Check {
    linenum: number;
    inverse: boolean;
    instatus: boolean;
    ingraphics: boolean;
    inrawdata: boolean;
    vital: boolean;
    ln: string;
    evaluate(state: GameState): string | null;
}

interface Command {
    type: string;
    cmd: string | null;
    x?: number;
    y?: number;
    width?: number | null;
    height?: number | null;
    checks: Check[];
}

interface RegTest {
    name: string;
    gamefile: string | null;
    terp: {path: string; args: string[]} | null;
    precmd: Command | null;
    cmds: Command[];
}

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const scriptDir = dirname(new URL(import.meta.url).pathname);
const interpDir = process.env.INTERP_DIR || join(scriptDir, "../zig-out/bin");
const platform = process.env.PLATFORM || "native";
const timeoutSecs = Number(process.env.TIMEOUT || "30");

let verbose = 0;
let vitalMode = 0;
let listonly = false;

// Global test state (reset per file)
let gamefile: string | null = null;
let terppath: string | null = null;
let terpargs: string[] = [];
let terpformat: "cheap" | "rem" | "remsingle" = "cheap";
let precommands: Command[] = [];
let testls: RegTest[] = [];
let testmap = new Map<string, RegTest>();
let totalerrors = 0;

// ---------------------------------------------------------------------------
// Glk key name mapping
// ---------------------------------------------------------------------------

const glkKeyNames: Record<string, number> = {
    left: 0xfffffffe, right: 0xfffffffd, up: 0xfffffffc,
    down: 0xfffffffb, return: 0xfffffffa, delete: 0xfffffff9,
    escape: 0xfffffff8, tab: 0xfffffff7, pageup: 0xfffffff6,
    pagedown: 0xfffffff5, home: 0xfffffff4, end: 0xfffffff3,
    func1: 0xffffffef, func2: 0xffffffee, func3: 0xffffffed,
    func4: 0xffffffec, func5: 0xffffffeb, func6: 0xffffffea,
    func7: 0xffffffe9, func8: 0xffffffe8, func9: 0xffffffe7,
    func10: 0xffffffe6, func11: 0xffffffe5, func12: 0xffffffe4,
};

// ---------------------------------------------------------------------------
// Command parsing
// ---------------------------------------------------------------------------

function parseCommand(raw: string, type?: string): Command {
    let cmd = raw;
    if (type === undefined) {
        const match = cmd.match(/^\{([a-z_]*)\}/);
        if (!match) {
            type = "line";
            cmd = cmd.trim();
        } else {
            type = match[1];
            cmd = cmd.slice(match[0].length).trim();
        }
    }

    const result: Command = {type, cmd: null, checks: []};

    switch (type) {
        case "line":
            result.cmd = cmd;
            break;
        case "char":
            if (cmd.length === 0) result.cmd = "\n";
            else if (cmd.length === 1) result.cmd = cmd;
            else if (cmd.toLowerCase() in glkKeyNames) result.cmd = cmd.toLowerCase();
            else if (cmd.toLowerCase() === "space") result.cmd = " ";
            else if (cmd.toLowerCase().startsWith("0x"))
                result.cmd = String.fromCodePoint(parseInt(cmd.slice(2), 16));
            else {
                const n = parseInt(cmd);
                if (!isNaN(n)) result.cmd = String.fromCodePoint(n);
                else throw new Error(`Unable to interpret char "${cmd}"`);
            }
            break;
        case "timer":
            break;
        case "hyperlink": {
            const n = parseInt(cmd);
            result.cmd = isNaN(n) ? cmd : String(n);
            break;
        }
        case "mouse": {
            const parts = cmd.split(/\s+/);
            result.x = parseInt(parts[0]);
            result.y = parseInt(parts[1]);
            result.cmd = `${result.x},${result.y}`;
            break;
        }
        case "refresh":
            break;
        case "arrange": {
            const parts = cmd.split(/\s+/);
            result.width = parts[0] ? parseInt(parts[0]) : null;
            result.height = parts[1] ? parseInt(parts[1]) : null;
            break;
        }
        case "include":
        case "fileref_prompt":
        case "debug":
            result.cmd = cmd;
            break;
        default:
            throw new Error(`Unknown command type: ${type}`);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Check classes
// ---------------------------------------------------------------------------

function buildCheck(ln: string, args: {linenum: number; inverse?: boolean; instatus?: boolean; ingraphics?: boolean; vital?: boolean}): Check {
    const base = {
        linenum: args.linenum,
        inverse: args.inverse || false,
        instatus: args.instatus || false,
        ingraphics: args.ingraphics || false,
        vital: args.vital || vitalMode > 0,
        inrawdata: false,
        ln,
    };

    // Select which window lines to check
    function getLines(check: Check, state: GameState): string[] {
        if (check.instatus) return state.statuswin;
        if (check.ingraphics) return state.graphicswin;
        return state.storywin;
    }

    function applyInverse(check: Check, res: string | null): string | null {
        if (!check.inverse) return res;
        return res ? null : "inverse test should fail";
    }

    // RegExp check
    if (ln.startsWith("/")) {
        const pattern = ln.slice(1).trim();
        return {
            ...base,
            ln: pattern,
            evaluate(state: GameState) {
                const lines = getLines(this, state);
                const re = new RegExp(pattern);
                const found = lines.some(l => re.test(l));
                return applyInverse(this, found ? null : "not found");
            },
        };
    }

    // LiteralCount check: {count=N}
    const countMatch = ln.match(/^\{count=(\d+)\}/);
    if (countMatch) {
        const count = parseInt(countMatch[1]);
        const text = ln.slice(countMatch[0].length).trim();
        return {
            ...base,
            ln: text,
            evaluate(state: GameState) {
                const lines = getLines(this, state);
                let counter = 0;
                for (const l of lines) {
                    let start = 0;
                    while (true) {
                        const pos = l.indexOf(text, start);
                        if (pos < 0) break;
                        counter++;
                        start = pos + 1;
                        if (counter >= count) break;
                    }
                    if (counter >= count) break;
                }
                const res = counter >= count ? null : counter === 0 ? "not found" : `only found ${counter} times`;
                return applyInverse(this, res);
            },
        };
    }

    // Default: literal check
    return {
        ...base,
        evaluate(state: GameState) {
            const lines = getLines(this, state);
            const found = lines.some(l => l.includes(this.ln));
            return applyInverse(this, found ? null : "not found");
        },
    };
}

function addCheck(cmd: Command, ln: string, linenum: number) {
    const args: {linenum: number; inverse?: boolean; instatus?: boolean; ingraphics?: boolean; vital?: boolean} = {linenum};

    // Peel off prefixes
    while (true) {
        const match = ln.match(/^(!|\{[a-z]*\})/);
        if (!match) break;
        ln = ln.slice(match[0].length).trim();
        const val = match[0];
        if (val === "!" || val === "{invert}") args.inverse = true;
        else if (val === "{status}") args.instatus = true;
        else if (val === "{graphic}" || val === "{graphics}") args.ingraphics = true;
        else if (val === "{vital}") args.vital = true;
        else throw new Error(`Unknown test modifier: ${val}`);
    }

    cmd.checks.push(buildCheck(ln, args));
}

// ---------------------------------------------------------------------------
// Test file parser
// ---------------------------------------------------------------------------

function parseTests(filename: string) {
    const content = readFileSync(filename, "utf-8");
    const lines = content.split("\n");

    let curtest: RegTest | null = null;
    let curcmd: Command | null = null;

    for (let i = 0; i < lines.length; i++) {
        const linenum = i + 1;
        const ln = lines[i].trim();
        if (!ln || ln.startsWith("#")) continue;

        // Global/test option
        if (ln.startsWith("**")) {
            const rest = ln.slice(2).trim();
            const pos = rest.indexOf(":");
            if (pos < 0) continue;
            const key = rest.slice(0, pos).trim();
            const val = rest.slice(pos + 1).trim();

            if (!curtest) {
                if (key === "pre" || key === "precommand") {
                    precommands.push(parseCommand(val));
                } else if (key === "game") {
                    gamefile = val;
                } else if (key === "interpreter") {
                    const parts = val.split(/\s+/);
                    terppath = parts[0];
                    terpargs = parts.slice(1);
                } else if (key === "remformat") {
                    terpformat = val.toLowerCase() > "og" ? "rem" : "cheap";
                } else if (key === "checkclass") {
                    // Custom check classes not supported in TS port
                } else {
                    throw new Error(`Unknown option: ** ${key}`);
                }
            } else {
                if (key === "game") {
                    curtest.gamefile = val;
                } else if (key === "interpreter") {
                    const parts = val.split(/\s+/);
                    curtest.terp = {path: parts[0], args: parts.slice(1)};
                } else {
                    throw new Error(`Unknown option: ** ${key} in * ${curtest.name}`);
                }
            }
            continue;
        }

        // Test block
        if (ln.startsWith("*")) {
            const name = ln.slice(1).trim();
            if (testmap.has(name)) throw new Error(`Test name used twice: ${name}`);
            curtest = {name, gamefile: null, terp: null, precmd: null, cmds: []};
            curcmd = parseCommand("(init)");
            curtest.precmd = curcmd;
            testls.push(curtest);
            testmap.set(name, curtest);
            continue;
        }

        // Command
        if (ln.startsWith(">")) {
            curcmd = parseCommand(ln.slice(1));
            curtest!.cmds.push(curcmd);
            continue;
        }

        // Check line
        addCheck(curcmd!, ln, linenum);
    }
}

// ---------------------------------------------------------------------------
// Game state (RemGlk protocol handler)
// ---------------------------------------------------------------------------

class GameState {
    storywin: string[] = [];
    statuswin: string[] = [];
    graphicswin: string[] = [];
    statuslinestarts = new Map<number, number>();
    windows = new Map<number, any>();
    generation = 0;
    lineinputwin: number | null = null;
    charinputwin: number | null = null;
    specialinput: string | null = null;
    hyperlinkinputwin: number | null = null;
    mouseinputwin: number | null = null;
    storywinResetPending = false;

    proc: ReturnType<typeof Bun.spawn> | null = null;
    reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
    leftover = "";

    async cleanup() {
        if (this.proc) {
            try { this.proc.stdin?.end(); } catch {}
            this.proc.kill();
            this.proc = null;
        }
    }

    async writeToInterp(data: string) {
        if (this.proc?.stdin) {
            this.proc.stdin.write(data + "\n");
            await this.proc.stdin.flush();
        }
    }

    /** Read a single complete JSON object from stdout with brace-depth tracking. */
    async readOneJson(): Promise<any | null> {
        const deadline = Date.now() + timeoutSecs * 1000;

        while (Date.now() < deadline) {
            // Try to extract a JSON object from leftover
            const trimmed = this.leftover.trimStart();
            if (trimmed.length > 0 && trimmed[0] === "{") {
                let depth = 0;
                let inStr = false;
                let esc = false;
                for (let i = 0; i < trimmed.length; i++) {
                    const ch = trimmed[i];
                    if (esc) { esc = false; continue; }
                    if (ch === "\\") { esc = true; continue; }
                    if (ch === '"') { inStr = !inStr; continue; }
                    if (inStr) continue;
                    if (ch === "{") depth++;
                    else if (ch === "}") {
                        depth--;
                        if (depth === 0) {
                            const jsonStr = trimmed.slice(0, i + 1);
                            this.leftover = trimmed.slice(i + 1);
                            try { return JSON.parse(jsonStr); } catch { /* keep reading */ }
                        }
                    }
                }
            }

            // Need more data
            if (!this.reader) return null;
            const remaining = deadline - Date.now();
            if (remaining <= 0) break;

            const result = await Promise.race([
                this.reader.read(),
                new Promise<{done: true; value: undefined}>(resolve =>
                    setTimeout(() => resolve({done: true, value: undefined}), remaining)
                ),
            ]);
            if (result.done || !result.value) {
                // EOF or timeout - try parsing what we have
                if (this.leftover.trim()) {
                    try { return JSON.parse(this.leftover.trim()); } catch {}
                }
                return null;
            }
            this.leftover += Buffer.from(result.value).toString("utf-8");
        }
        return null;
    }

    static createMetrics(width = 800, height = 480) {
        return {
            width, height,
            gridcharwidth: 10, gridcharheight: 12,
            buffercharwidth: 10, buffercharheight: 12,
        };
    }

    static extractText(line: any): string {
        const con = line.content;
        if (!con) return "";
        const parts: string[] = [];
        let i = 0;
        while (i < con.length) {
            const val = con[i];
            i++;
            if (typeof val === "object" && val !== null) {
                parts.push(val.text || "");
            } else {
                parts.push(con[i] || "");
                i++;
            }
        }
        return parts.join("");
    }

    async initialize() {
        const update = {
            type: "init", gen: 0,
            metrics: GameState.createMetrics(),
            support: ["timer", "hyperlinks", "graphics", "graphicswin", "graphicsext"],
        };
        await this.writeToInterp(JSON.stringify(update));
    }

    async performInput(cmd: Command) {
        let update: any;
        switch (cmd.type) {
            case "line":
                if (!this.lineinputwin) throw new Error("Game is not expecting line input");
                update = {type: "line", gen: this.generation, window: this.lineinputwin, value: cmd.cmd};
                break;
            case "char":
                if (!this.charinputwin) throw new Error("Game is not expecting char input");
                update = {type: "char", gen: this.generation, window: this.charinputwin,
                    value: cmd.cmd === "\n" ? "return" : cmd.cmd};
                break;
            case "hyperlink":
                if (!this.hyperlinkinputwin) throw new Error("Game is not expecting hyperlink input");
                update = {type: "hyperlink", gen: this.generation, window: this.hyperlinkinputwin, value: cmd.cmd};
                break;
            case "mouse":
                if (!this.mouseinputwin) throw new Error("Game is not expecting mouse input");
                update = {type: "mouse", gen: this.generation, window: this.mouseinputwin, x: cmd.x, y: cmd.y};
                break;
            case "timer":
                update = {type: "timer", gen: this.generation};
                break;
            case "arrange":
                update = {type: "arrange", gen: this.generation,
                    metrics: GameState.createMetrics(cmd.width ?? undefined, cmd.height ?? undefined)};
                break;
            case "refresh":
                update = {type: "refresh", gen: 0};
                break;
            case "fileref_prompt":
                if (this.specialinput !== "fileref_prompt") throw new Error("Game is not expecting a fileref_prompt");
                update = {type: "specialresponse", gen: this.generation, response: "fileref_prompt", value: cmd.cmd};
                break;
            case "debug":
                update = {type: "debuginput", gen: this.generation, value: cmd.cmd};
                break;
            default:
                throw new Error(`Rem mode does not recognize command type: ${cmd.type}`);
        }
        if (verbose >= 2) console.log(JSON.stringify(update, null, 2));
        await this.writeToInterp(JSON.stringify(update));
    }

    async acceptOutput() {
        const deadline = Date.now() + timeoutSecs * 1000;
        this.storywinResetPending = true;

        while (true) {
            if (Date.now() >= deadline) throw new Error("Timed out awaiting output");
            const update = await this.readOneJson();
            if (!update) break;
            this.parseRemGlkUpdate(update);
            if (update.exit) break;
            if (update.input !== undefined || update.specialinput !== undefined) break;
            if (!update.disable) break;
        }
    }

    parseRemGlkUpdate(update: any) {
        if (verbose >= 2) console.log(JSON.stringify(update, null, 2));

        this.generation = update.gen;

        if (update.windows !== undefined) {
            this.windows.clear();
            for (const win of update.windows) this.windows.set(win.id, win);

            const grids = [...this.windows.values()].filter(w => w.type === "grid");
            let totalheight = 0;
            this.statuslinestarts.clear();
            for (const win of grids) {
                this.statuslinestarts.set(win.id, totalheight);
                totalheight += win.gridheight || 0;
            }
            if (totalheight < this.statuswin.length) this.statuswin.length = totalheight;
            while (totalheight > this.statuswin.length) this.statuswin.push("");
        }

        if (update.content !== undefined) {
            for (const content of update.content) {
                const win = this.windows.get(content.id);
                if (!win) throw new Error("No such window");

                if (win.type === "buffer") {
                    if (this.storywinResetPending) {
                        this.storywin = [];
                        this.storywinResetPending = false;
                    }
                    if (content.text) {
                        for (const line of content.text) {
                            const dat = GameState.extractText(line);
                            if (verbose === 1 && dat !== ">") console.log(dat);
                            if (line.append && this.storywin.length > 0)
                                this.storywin[this.storywin.length - 1] += dat;
                            else
                                this.storywin.push(dat);
                        }
                    }
                } else if (win.type === "grid") {
                    if (content.lines) {
                        for (const line of content.lines) {
                            const lineStart = this.statuslinestarts.get(content.id) || 0;
                            const linenum = lineStart + line.line;
                            const dat = GameState.extractText(line);
                            if (linenum >= 0 && linenum < this.statuswin.length)
                                this.statuswin[linenum] = dat;
                        }
                    }
                } else if (win.type === "graphics") {
                    this.graphicswin = [];
                }
            }
        }

        const inputs = update.input;
        const specialinputs = update.specialinput;
        if (specialinputs !== undefined) {
            this.specialinput = specialinputs.type;
            this.lineinputwin = this.charinputwin = this.hyperlinkinputwin = this.mouseinputwin = null;
        } else if (inputs !== undefined) {
            this.specialinput = null;
            this.lineinputwin = this.charinputwin = this.hyperlinkinputwin = this.mouseinputwin = null;
            for (const input of inputs) {
                if (input.type === "line") {
                    if (this.lineinputwin) throw new Error("Multiple windows accepting line input");
                    this.lineinputwin = input.id;
                }
                if (input.type === "char") {
                    if (this.charinputwin) throw new Error("Multiple windows accepting char input");
                    this.charinputwin = input.id;
                }
                if (input.hyperlink) this.hyperlinkinputwin = input.id;
                if (input.mouse) this.mouseinputwin = input.id;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Command list expansion (handles {include})
// ---------------------------------------------------------------------------

function listCommands(cmds: Command[], result: Command[] = [], nested = new Set<string>()): Command[] {
    for (const cmd of cmds) {
        if (cmd.type === "include") {
            if (nested.has(cmd.cmd!)) throw new Error(`Included test includes itself: ${cmd.cmd}`);
            const test = testmap.get(cmd.cmd!);
            if (!test) throw new Error(`Included test not found: ${cmd.cmd}`);
            const newNested = new Set(nested);
            newNested.add(cmd.cmd!);
            listCommands(test.cmds, result, newNested);
            continue;
        }
        result.push(cmd);
    }
    return result;
}

// ---------------------------------------------------------------------------
// Interpreter mapping (from run-regtest.sh)
// ---------------------------------------------------------------------------

function getInterpreter(gameFile: string): string | null {
    if (gameFile.endsWith(".ulx")) return "glulxe";
    if (/\.z\d$/.test(gameFile)) return "bocfel";
    if (gameFile.endsWith(".hex")) return "hugo";
    return null;
}

function getInterpCmd(interpName: string): string[] {
    if (platform === "wasm") {
        return ["wasmtime", "run", "--dir=.", join(interpDir, `${interpName}.wasm`), "--"];
    }
    return [join(interpDir, interpName)];
}

// ---------------------------------------------------------------------------
// Run a single test
// ---------------------------------------------------------------------------

class VitalCheckError extends Error {}

async function runTest(test: RegTest): Promise<void> {
    const testgamefile = test.gamefile || gamefile;
    const testterppath = test.terp?.path || terppath;
    const testterpargs = test.terp?.args || terpargs;

    console.log(`* ${test.name}`);
    const args = [testterppath!, ...testterpargs, testgamefile!];

    const state = new GameState();

    if (terpformat !== "remsingle") {
        state.proc = Bun.spawn(args, {
            stdin: "pipe",
            stdout: "pipe",
            stderr: "inherit",
            cwd: scriptDir,
        });
        state.reader = state.proc.stdout.getReader();
    }

    const cmdlist = listCommands([...precommands, ...test.cmds]);

    try {
        if (terpformat === "rem" || terpformat === "remsingle") {
            await state.initialize();
        }
        await state.acceptOutput();

        if (test.precmd) {
            for (const check of test.precmd.checks) {
                const res = check.evaluate(state);
                if (res) {
                    totalerrors++;
                    const prefix = verbose ? "*** " : "";
                    console.log(`${prefix}<Check:${check.linenum} "${truncate(check.ln)}">${check.inverse ? "!" : ""}: ${res}`);
                    if (check.vital) throw new VitalCheckError();
                }
            }
        }

        for (const cmd of cmdlist) {
            if (verbose) {
                if (cmd.type === "line") {
                    if (terpformat === "cheap") console.log(`> ${cmd.cmd}`);
                    else process.stdout.write("> ");
                } else {
                    console.log(`> {${cmd.type}} ${JSON.stringify(cmd.cmd)}`);
                }
            }
            await state.performInput(cmd);
            await state.acceptOutput();

            for (const check of cmd.checks) {
                const res = check.evaluate(state);
                if (res) {
                    totalerrors++;
                    const prefix = verbose ? "*** " : "";
                    console.log(`${prefix}<Check:${check.linenum} "${truncate(check.ln)}">${check.inverse ? "!" : ""}: ${res}`);
                    if (check.vital) throw new VitalCheckError();
                }
            }
        }
    } catch (e) {
        if (e instanceof VitalCheckError) {
            // Already logged
        } else {
            totalerrors++;
            const prefix = verbose ? "*** " : "";
            console.log(`${prefix}${(e as Error).constructor.name}: ${(e as Error).message}`);
        }
    } finally {
        await state.cleanup();
    }
}

function truncate(s: string, max = 40): string {
    return s.length > max && !verbose ? s.slice(0, max) + "..." : s;
}

// ---------------------------------------------------------------------------
// Runner logic (from run-regtest.sh)
// ---------------------------------------------------------------------------

function resetGlobalState() {
    gamefile = null;
    terppath = null;
    terpargs = [];
    terpformat = "cheap";
    precommands = [];
    testls = [];
    testmap = new Map();
    totalerrors = 0;
}

function matchGlob(name: string, pattern: string): boolean {
    if (pattern === "*") return true;
    const re = new RegExp("^" + pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".") + "$");
    return re.test(name);
}

async function runRegtestFile(regtestFile: string, section?: string): Promise<boolean> {
    // Read file to find game
    const content = readFileSync(regtestFile, "utf-8");
    const gameMatch = content.match(/^\*\* game:\s*(.+)/m);
    if (!gameMatch) {
        console.log(`ERROR: No game file specified in ${regtestFile}`);
        return false;
    }
    const gameFile = gameMatch[1].trim();
    const interpName = getInterpreter(gameFile);
    if (!interpName) {
        console.log(`SKIP: Unknown game format for ${gameFile}`);
        return true;
    }

    // Check interpreter exists
    const interpPath = platform === "wasm"
        ? join(interpDir, `${interpName}.wasm`)
        : join(interpDir, interpName);
    if (!existsSync(interpPath)) {
        console.log(`SKIP: Interpreter ${interpPath} not found`);
        return true;
    }

    const interpCmd = getInterpCmd(interpName);

    // Reset and parse
    resetGlobalState();
    parseTests(regtestFile);

    // Override with our interpreter command and rem format
    terppath = interpCmd[0];
    terpargs = interpCmd.slice(1);
    terpformat = "rem";

    const testnames = section ? [section] : ["*"];

    console.log(`--- Testing: ${basename(regtestFile)}${section ? ` (section: ${section})` : ""} with ${interpName} ---`);

    let testcount = 0;

    for (const test of testls) {
        let use = false;
        for (const pat of testnames) {
            if (pat === "*" && (test.name.startsWith("-") || test.name.startsWith("_"))) continue;
            if (matchGlob(test.name, pat)) { use = true; break; }
        }
        if (use) {
            testcount++;
            if (listonly) console.log(test.name);
            else {
                await runTest(test);
                if (totalerrors && vitalMode >= 2) break;
            }
        }
    }

    if (testcount === 0) console.log("No tests performed!");
    return totalerrors === 0;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
    const args = process.argv.slice(2);
    const positional: string[] = [];

    for (const arg of args) {
        if (arg === "-v" || arg === "--verbose") verbose++;
        else if (arg === "-l" || arg === "--list") listonly = true;
        else if (arg === "--vital") vitalMode++;
        else positional.push(arg);
    }

    const gameFilter = positional[0];
    const section = positional[1];

    let passed = 0;
    let failed = 0;

    if (gameFilter) {
        const regtestFiles = readdirSync(scriptDir)
            .filter(f => f.endsWith(".regtest") && f.includes(gameFilter))
            .map(f => join(scriptDir, f));
        if (regtestFiles.length === 0) {
            console.error(`No regtest files matching '${gameFilter}'`);
            process.exit(1);
        }
        for (const f of regtestFiles) {
            if (await runRegtestFile(f, section)) passed++; else failed++;
        }
    } else {
        const regtestFiles = readdirSync(scriptDir)
            .filter(f => f.endsWith(".regtest") && !f.includes("profiler"))
            .sort()
            .map(f => join(scriptDir, f));
        for (const f of regtestFiles) {
            if (await runRegtestFile(f)) passed++; else failed++;
        }
    }

    console.log();
    console.log(`=== Results: ${passed} passed, ${failed} failed ===`);
    if (failed > 0) process.exit(1);
}

main().catch(e => { console.error(e); process.exit(1); });
