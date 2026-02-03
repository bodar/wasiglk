const std = @import("std");

// wasiglk build.zig - Compile IF interpreters using Zig
//
// Supports multiple targets:
//   zig build                     # Build for WASI (default)
//   zig build -Dtarget=native     # Build for native host (Linux, macOS, etc.)
//   zig build -Dtarget=wasi       # Build for WASI explicitly

pub fn build(b: *std.Build) void {
    // Platform selection: native or wasi (default)
    // Usage: zig build -Dplatform=native  OR  zig build -Dplatform=wasi
    const platform = b.option([]const u8, "platform", "Target platform: 'native' or 'wasi' (default)") orelse "wasi";

    const is_native = std.mem.eql(u8, platform, "native");
    const target = if (is_native)
        b.standardTargetOptions(.{})
    else
        b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    const optimize = b.standardOptimizeOption(.{});

    // Build WASI-Glk as a compiled object (shared by all interpreters)
    const wasi_glk = buildWasiGlk(b, target, optimize);

    // Build all interpreters (C-based, work on both native and WASM)
    const interpreters = .{
        .{ "glulxe", "Build Glulxe interpreter", buildGlulxe },
        .{ "git", "Build Git interpreter", buildGit },
        .{ "hugo", "Build Hugo interpreter", buildHugo },
    };

    inline for (interpreters) |info| {
        const exe = info[2](b, target, optimize, wasi_glk);
        const install = b.addInstallArtifact(exe, .{});
        b.step(info[0], info[1]).dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }

    // Native-only interpreters
    // - Bocfel/TADS: WASM blocked by wasi-sdk lacking C++ exception support
    //   Tracking: https://github.com/WebAssembly/wasi-sdk/issues/565
    // - Scare: WASM blocked by zlib dependency (wasi-sdk doesn't include zlib)
    if (is_native) {
        const bocfel = buildBocfel(b, target, optimize, wasi_glk);
        const bocfel_install = b.addInstallArtifact(bocfel, .{});
        b.step("bocfel", "Build Bocfel interpreter (native only)").dependOn(&bocfel_install.step);
        b.getInstallStep().dependOn(&bocfel_install.step);

        const tads = buildTads(b, target, optimize, wasi_glk);
        const tads_install = b.addInstallArtifact(tads, .{});
        b.step("tads", "Build TADS 2/3 interpreter (native only)").dependOn(&tads_install.step);
        b.getInstallStep().dependOn(&tads_install.step);

        const scare = buildScare(b, target, optimize, wasi_glk);
        const scare_install = b.addInstallArtifact(scare, .{});
        b.step("scare", "Build Scare interpreter (native only)").dependOn(&scare_install.step);
        b.getInstallStep().dependOn(&scare_install.step);
    }
}

// Build the WASI-Glk implementation from Zig source
fn buildWasiGlk(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addObject(.{
        .name = "wasi_glk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasi_glk.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
}

fn buildGlulxe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "glulxe",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    exe.addCSourceFiles(.{
        .root = b.path("glulxe"),
        .files = &.{
            "accel.c",   "debugger.c",     "exec.c",   "files.c",
            "float.c",   "funcs.c",        "gestalt.c", "glkop.c",
            "heap.c",    "main.c",         "operand.c", "osdepend.c",
            "profile.c", "search.c",       "serial.c", "string.c",
            "vm.c",      "unixstrt.c",     "unixautosave.c",
        },
        .flags = &.{
            "-DOS_UNIX", "-Wall", "-Wmissing-prototypes", "-Wno-unused",
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    addGlkSupport(exe, b, wasi_glk, true);
    exe.addIncludePath(b.path("glulxe"));

    return exe;
}

fn buildGit(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    // Git requires setjmp/longjmp which needs WASM exception handling.
    // Create a target with exception_handling CPU feature enabled.
    const git_target = if (target.result.cpu.arch == .wasm32)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        })
    else
        target;

    const exe = b.addExecutable(.{
        .name = "git",
        .root_module = b.createModule(.{ .target = git_target, .optimize = optimize }),
    });

    exe.addCSourceFiles(.{
        .root = b.path("git"),
        .files = &.{
            "accel.c",    "compiler.c", "gestalt.c",  "git.c",
            "glkop.c",    "heap.c",     "memory.c",   "opcodes.c",
            "operands.c", "peephole.c", "savefile.c", "saveundo.c",
            "search.c",   "terp.c",     "git_unix.c",
        },
        .flags = &.{
            "-DUSE_DIRECT_THREADING",    "-DUSE_INLINE",
            "-Wall",                     "-Wno-int-conversion",
            "-Wno-pointer-sign",         "-Wno-unused-but-set-variable",
            "-D_WASI_EMULATED_SIGNAL",
            // Enable setjmp/longjmp via WASM exception handling
            "-mllvm",                    "-wasm-enable-sjlj",
            "-mllvm",                    "-wasm-use-legacy-eh=false",
        },
    });

    // Add git-specific compatibility shims
    exe.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"git_compat.c"},
        .flags = &.{"-D_WASI_EMULATED_SIGNAL"},
    });

    // Link precompiled libsetjmp from wasi-sdk (required for setjmp/longjmp support).
    // The runtime can't be compiled with current LLVM due to a bug with __builtin_wasm_throw.
    // See: https://github.com/llvm/llvm-project - "undefined tag symbol cannot be weak"
    if (git_target.result.cpu.arch == .wasm32) {
        // Try to find wasi-sdk's libsetjmp.a via environment or common paths
        const wasi_sdk_path = std.process.getEnvVarOwned(b.allocator, "WASI_SDK_PATH") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
                // Try mise's default location
                const home = std.process.getEnvVarOwned(b.allocator, "HOME") catch break :blk null;
                break :blk std.fmt.allocPrint(b.allocator, "{s}/.local/share/mise/installs/wasi-sdk/27/wasi-sdk", .{home}) catch null;
            }
            break :blk null;
        };
        if (wasi_sdk_path) |sdk_path| {
            const libsetjmp_path = std.fmt.allocPrint(b.allocator, "{s}/share/wasi-sysroot/lib/wasm32-wasi/libsetjmp.a", .{sdk_path}) catch null;
            if (libsetjmp_path) |path| {
                exe.addObjectFile(.{ .cwd_relative = path });
            }
        }
    }

    addGlkSupport(exe, b, wasi_glk, true);
    exe.addIncludePath(b.path("git"));

    return exe;
}

fn buildHugo(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "hugo",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const hugo_flags: []const []const u8 = &.{
        "-DCOMPILE_V25",              "-DGLK",
        "-DNO_KEYPRESS_CURSOR",       "-DHUGO_INLINE=static inline",
        "-Wall",                      "-Wno-unused-but-set-variable",
        "-D_WASI_EMULATED_SIGNAL",
    };

    exe.addCSourceFiles(.{
        .root = b.path("hugo/source"),
        .files = &.{
            "he.c",      "heexpr.c",  "hemisc.c",   "heobject.c",
            "heparse.c", "heres.c",   "herun.c",    "heset.c",
            "stringfn.c",
        },
        .flags = hugo_flags,
    });

    exe.addCSourceFiles(.{
        .root = b.path("hugo/heglk"),
        .files = &.{ "heglk.c", "heglkunix.c" },
        .flags = hugo_flags,
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("hugo/source"));
    exe.addIncludePath(b.path("hugo/heglk"));

    return exe;
}

fn buildScare(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "scare",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const scare_flags: []const []const u8 = &.{
        "-Wall",
        "-Wno-pointer-sign",
        "-D_WASI_EMULATED_SIGNAL",
        "-DSCARE_NO_ABBREVIATIONS",
    };

    // Core SCARE interpreter files
    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/scare"),
        .files = &.{
            "sctafpar.c",  "sctaffil.c", "scprops.c",  "scvars.c",
            "scexpr.c",    "scprintf.c", "scinterf.c", "scparser.c",
            "sclibrar.c",  "scrunner.c", "scevents.c", "scnpcs.c",
            "scobjcts.c",  "sctasks.c",  "screstrs.c", "scgamest.c",
            "scserial.c",  "scresour.c", "scmemos.c",  "scutils.c",
            "sclocale.c",  "scdebug.c",  "os_glk.c",
        },
        .flags = scare_flags,
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("garglk/terps/scare"));
    exe.linkSystemLibrary("z"); // zlib for TAF decompression

    return exe;
}

fn buildBocfel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "bocfel",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    // Note: For WASM builds (future), would need:
    //   - ZTERP_GLK_NO_STDIO (route file I/O through Glk, not stdio)
    //   - fstream stubs (bocfel uses std::ifstream for config/patches)
    //   - C++ exception support in wasi-sdk
    const bocfel_flags: []const []const u8 = &.{
        "-DZTERP_GLK",
        "-DZTERP_GLK_BLORB",
        "-DZTERP_GLK_UNIX",
        "-Wall",
        "-std=c++14",
        "-fexceptions", // Required - bocfel uses exceptions for control flow
    };

    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/bocfel"),
        .files = &.{
            "blorb.cpp",    "branch.cpp",  "dict.cpp",    "glkautosave.cpp",
            "glkstart.cpp", "iff.cpp",     "io.cpp",      "mathop.cpp",
            "meta.cpp",     "memory.cpp",  "objects.cpp", "options.cpp",
            "osdep.cpp",    "patches.cpp", "process.cpp", "random.cpp",
            "screen.cpp",   "sound.cpp",   "stack.cpp",   "stash.cpp",
            "unicode.cpp",  "util.cpp",    "zoom.cpp",    "zterp.cpp",
        },
        .flags = bocfel_flags,
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("garglk/terps/bocfel"));
    exe.linkLibCpp();

    return exe;
}

fn buildTads(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "tads",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const tads_c_flags: []const []const u8 = &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DTC_TARGET_T3",
        "-DRUNTIME",
        "-DVMGLOB_STRUCT",
        "-Wall",
        "-Wno-pointer-sign",
        "-Wno-parentheses",
    };

    const tads_cpp_flags: []const []const u8 = &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DTC_TARGET_T3",
        "-DRUNTIME",
        "-DVMGLOB_STRUCT",
        "-Wall",
        "-std=c++11",
        "-Wno-deprecated-register",
        "-Wno-logical-not-parentheses",
        "-Wno-pointer-sign",
        "-Wno-string-concatenation",
    };

    // TADS Glk interface layer (mixed C and C++)
    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/tads/glk"),
        .files = &.{
            "memicmp.c",  "osbuffer.c", "osextra.c",  "osglk.c",
            "osglkban.c", "osmisc.c",   "osparse.c",  "t2askf.c",
            "t2indlg.c",
        },
        .flags = tads_c_flags,
    });

    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/tads/glk"),
        .files = &.{
            "osportable.cc", "t23run.cpp", "t3askf.cpp",
            "t3indlg.cpp",   "vmuni_cs.cpp",
        },
        .flags = tads_cpp_flags,
    });

    // TADS 2 runtime (C)
    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/tads/tads2"),
        .files = &.{
            "argize.c",   "bif.c",      "bifgdum.c",  "cmap.c",
            "cmd.c",      "dat.c",      "dbgtr.c",    "errmsg.c",
            "execmd.c",   "fio.c",      "fioxor.c",   "getstr.c",
            "ler.c",      "linfdum.c",  "lst.c",      "mch.c",
            "mcm.c",      "mcs.c",      "obj.c",      "oem.c",
            "os0.c",      "oserr.c",    "osifc.c",    "osnoui.c",
            "osrestad.c", "osstzprs.c", "ostzposix.c", "out.c",
            "output.c",   "ply.c",      "qas.c",      "regex.c",
            "run.c",      "runstat.c",  "suprun.c",   "trd.c",
            "voc.c",      "vocab.c",
        },
        .flags = tads_c_flags,
    });

    // TADS 3 VM (C++)
    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/tads/tads3"),
        .files = &.{
            "charmap.cpp",     "md5.cpp",         "resldexe.cpp",    "resload.cpp",
            "sha2.cpp",        "std.cpp",         "tcerr.cpp",       "tcerrmsg.cpp",
            "tcgen.cpp",       "tcglob.cpp",      "tcmain.cpp",      "tcprs.cpp",
            "tcprs_rt.cpp",    "tcprsnf.cpp",     "tcprsnl.cpp",     "tcprsstm.cpp",
            "tcsrc.cpp",       "tct3.cpp",        "tct3_d.cpp",      "tct3nl.cpp",
            "tct3stm.cpp",     "tct3unas.cpp",    "tctok.cpp",       "utf8.cpp",
            "vmanonfn.cpp",    "vmbif.cpp",       "vmbifl.cpp",      "vmbifreg.cpp",
            "vmbift3.cpp",     "vmbiftad.cpp",    "vmbiftio.cpp",    "vmbignum.cpp",
            "vmbignumlib.cpp", "vmbt3_nd.cpp",    "vmbytarr.cpp",    "vmcfgmem.cpp",
            "vmcoll.cpp",      "vmconhmp.cpp",    "vmconsol.cpp",    "vmcrc.cpp",
            "vmcset.cpp",      "vmdate.cpp",      "vmdict.cpp",      "vmdynfunc.cpp",
            "vmerr.cpp",       "vmerrmsg.cpp",    "vmfile.cpp",      "vmfilnam.cpp",
            "vmfilobj.cpp",    "vmfref.cpp",      "vmfunc.cpp",      "vmglob.cpp",
            "vmgram.cpp",      "vmhash.cpp",      "vmhostsi.cpp",    "vmhosttx.cpp",
            "vmimage.cpp",     "vmimg_nd.cpp",    "vmini_nd.cpp",    "vminit.cpp",
            "vminitim.cpp",    "vmintcls.cpp",    "vmisaac.cpp",     "vmiter.cpp",
            "vmlog.cpp",       "vmlookup.cpp",    "vmlst.cpp",       "vmmain.cpp",
            "vmmcreg.cpp",     "vmmeta.cpp",      "vmnetfillcl.cpp", "vmobj.cpp",
            "vmop.cpp",        "vmpack.cpp",      "vmpat.cpp",       "vmpool.cpp",
            "vmpoolim.cpp",    "vmregex.cpp",     "vmrun.cpp",       "vmrunsym.cpp",
            "vmsa.cpp",        "vmsave.cpp",      "vmsort.cpp",      "vmsortv.cpp",
            "vmsrcf.cpp",      "vmstack.cpp",     "vmstr.cpp",       "vmstrbuf.cpp",
            "vmstrcmp.cpp",    "vmtmpfil.cpp",    "vmtobj.cpp",      "vmtype.cpp",
            "vmtypedh.cpp",    "vmtz.cpp",        "vmtzobj.cpp",     "vmundo.cpp",
            "vmvec.cpp",       "vmconnom.cpp",
        },
        .flags = tads_cpp_flags,
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("garglk/terps/tads/glk"));
    exe.addIncludePath(b.path("garglk/terps/tads/tads2"));
    exe.addIncludePath(b.path("garglk/terps/tads/tads3"));
    exe.linkLibCpp();

    return exe;
}

// Helper to add common Glk support to an executable
fn addGlkSupport(exe: *std.Build.Step.Compile, b: *std.Build, wasi_glk: *std.Build.Step.Compile, include_dispa: bool) void {
    exe.addObject(wasi_glk);

    exe.addCSourceFiles(.{
        .root = b.path("src"),
        .files = if (include_dispa)
            &.{ "gi_dispa.c", "gi_blorb.c" }
        else
            &.{"gi_blorb.c"},
        .flags = &.{"-D_WASI_EMULATED_SIGNAL"},
    });

    exe.addIncludePath(b.path("src"));
    exe.linkLibC();
}
