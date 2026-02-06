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

    // Build zlib (used by Scare)
    const zlib = buildZlib(b, target, optimize);

    // Build all interpreters (C-based, work on both native and WASM)
    const interpreters = .{
        .{ "glulxe", "Build Glulxe interpreter", buildGlulxe },
        .{ "git", "Build Git interpreter", buildGit },
        .{ "hugo", "Build Hugo interpreter", buildHugo },
        .{ "agility", "Build Agility interpreter (AGT)", buildAgility },
        .{ "jacl", "Build JACL interpreter", buildJacl },
        .{ "level9", "Build Level 9 interpreter", buildLevel9 },
        .{ "magnetic", "Build Magnetic interpreter", buildMagnetic },
        .{ "fizmo", "Build Fizmo interpreter (Z-machine)", buildFizmo },
    };

    inline for (interpreters) |info| {
        const exe = info[2](b, target, optimize, wasi_glk);
        const install = b.addInstallArtifact(exe, .{});
        b.step(info[0], info[1]).dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }

    // Interpreters that need setjmp/longjmp (WASM exception handling)
    const setjmp_interpreters = .{
        .{ "advsys", "Build AdvSys interpreter", buildAdvsys },
        .{ "alan2", "Build Alan 2 interpreter", buildAlan2 },
        .{ "alan3", "Build Alan 3 interpreter", buildAlan3 },
    };

    inline for (setjmp_interpreters) |info| {
        const exe = info[2](b, target, optimize, wasi_glk);
        const install = b.addInstallArtifact(exe, .{});
        b.step(info[0], info[1]).dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }

    // Scare (needs zlib + setjmp, works on both native and WASM)
    const scare = buildScare(b, target, optimize, wasi_glk, zlib);
    const scare_install = b.addInstallArtifact(scare, .{});
    b.step("scare", "Build Scare interpreter (ADRIFT)").dependOn(&scare_install.step);
    b.getInstallStep().dependOn(&scare_install.step);

    // TADS 2 (pure C, no TADS 3 code) and TADS 3 (C++, no TADS 2 code)
    // Both use setjmp/longjmp (not C++ exceptions)
    const tads2 = buildTads2(b, target, optimize, wasi_glk);
    const tads2_install = b.addInstallArtifact(tads2, .{});
    b.step("tads2", "Build TADS 2 interpreter").dependOn(&tads2_install.step);
    b.getInstallStep().dependOn(&tads2_install.step);

    const tads3 = buildTads3(b, target, optimize, wasi_glk);
    const tads3_install = b.addInstallArtifact(tads3, .{});
    b.step("tads3", "Build TADS 3 interpreter").dependOn(&tads3_install.step);
    b.getInstallStep().dependOn(&tads3_install.step);

    // Native-only interpreters (C++ with actual throw/catch exceptions)
    // WASM blocked by wasi-sdk lacking C++ exception support
    // Tracking: https://github.com/WebAssembly/wasi-sdk/issues/565
    if (is_native) {
        const bocfel = buildBocfel(b, target, optimize, wasi_glk);
        const bocfel_install = b.addInstallArtifact(bocfel, .{});
        b.step("bocfel", "Build Bocfel interpreter (native only)").dependOn(&bocfel_install.step);
        b.getInstallStep().dependOn(&bocfel_install.step);
    }
}

// Build the WASI-Glk implementation from Zig source
fn buildWasiGlk(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addObject(.{
        .name = "wasi_glk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
}

// Build zlib as a static library
fn buildZlib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "z",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const zlib_flags: []const []const u8 = &.{
        "-DHAVE_UNISTD_H",
        "-DHAVE_STDARG_H",
    };

    lib.addCSourceFiles(.{
        .root = b.path("../zlib"),
        .files = &.{
            "adler32.c",
            "crc32.c",
            "deflate.c",
            "infback.c",
            "inffast.c",
            "inflate.c",
            "inftrees.c",
            "trees.c",
            "zutil.c",
            "compress.c",
            "uncompr.c",
            "gzclose.c",
            "gzlib.c",
            "gzread.c",
            "gzwrite.c",
        },
        .flags = zlib_flags,
    });

    lib.addIncludePath(b.path("../zlib"));
    lib.linkLibC();

    return lib;
}

fn buildGlulxe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "glulxe",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    exe.addCSourceFiles(.{
        .root = b.path("../glulxe"),
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
    exe.addIncludePath(b.path("../glulxe"));

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
        .root = b.path("../git"),
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
    exe.addIncludePath(b.path("../git"));

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
        .root = b.path("../hugo/source"),
        .files = &.{
            "he.c",      "heexpr.c",  "hemisc.c",   "heobject.c",
            "heparse.c", "heres.c",   "herun.c",    "heset.c",
            "stringfn.c",
        },
        .flags = hugo_flags,
    });

    exe.addCSourceFiles(.{
        .root = b.path("../hugo/heglk"),
        .files = &.{ "heglk.c", "heglkunix.c" },
        .flags = hugo_flags,
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../hugo/source"));
    exe.addIncludePath(b.path("../hugo/heglk"));

    return exe;
}

fn buildScare(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile, zlib: *std.Build.Step.Compile) *std.Build.Step.Compile {
    // Scare uses setjmp/longjmp which needs WASM exception handling.
    const scare_target = if (target.result.cpu.arch == .wasm32)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        })
    else
        target;

    const exe = b.addExecutable(.{
        .name = "scare",
        .root_module = b.createModule(.{ .target = scare_target, .optimize = optimize }),
    });

    const scare_files = &[_][]const u8{
        "sctafpar.c",  "sctaffil.c", "scprops.c",  "scvars.c",
        "scexpr.c",    "scprintf.c", "scinterf.c", "scparser.c",
        "sclibrar.c",  "scrunner.c", "scevents.c", "scnpcs.c",
        "scobjcts.c",  "sctasks.c",  "screstrs.c", "scgamest.c",
        "scserial.c",  "scresour.c", "scmemos.c",  "scutils.c",
        "sclocale.c",  "scdebug.c",  "os_glk.c",
    };

    // Different flags for native vs WASM (WASM needs setjmp/longjmp support)
    if (scare_target.result.cpu.arch == .wasm32) {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/scare"),
            .files = scare_files,
            .flags = &.{
                "-Wall",
                "-Wno-pointer-sign",
                "-D_WASI_EMULATED_SIGNAL",
                "-DSCARE_NO_ABBREVIATIONS",
                "-mllvm", "-wasm-enable-sjlj",
                "-mllvm", "-wasm-use-legacy-eh=false",
            },
        });

        // Link precompiled libsetjmp from wasi-sdk
        const wasi_sdk_path = std.process.getEnvVarOwned(b.allocator, "WASI_SDK_PATH") catch |err| blk: {
            if (err == error.EnvironmentVariableNotFound) {
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
    } else {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/scare"),
            .files = scare_files,
            .flags = &.{
                "-Wall",
                "-Wno-pointer-sign",
                "-D_WASI_EMULATED_SIGNAL",
                "-DSCARE_NO_ABBREVIATIONS",
            },
        });
    }

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/scare"));

    // Link zlib (built from source)
    exe.linkLibrary(zlib);
    exe.addIncludePath(b.path("../zlib"));

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
        .root = b.path("../garglk/terps/bocfel"),
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
    exe.addIncludePath(b.path("../garglk/terps/bocfel"));
    exe.linkLibCpp();

    return exe;
}

fn buildTads2(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    // TADS 2 uses setjmp/longjmp for error handling.
    const tads2_target = if (target.result.cpu.arch == .wasm32)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        })
    else
        target;

    const is_wasm = tads2_target.result.cpu.arch == .wasm32;

    const exe = b.addExecutable(.{
        .name = "tads2",
        .root_module = b.createModule(.{ .target = tads2_target, .optimize = optimize }),
    });

    const tads2_c_flags: []const []const u8 = if (is_wasm) &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DRUNTIME",
        "-Wall",
        "-Wno-pointer-sign",
        "-Wno-parentheses",
        "-D_WASI_EMULATED_SIGNAL",
        "-mllvm", "-wasm-enable-sjlj",
        "-mllvm", "-wasm-use-legacy-eh=false",
    } else &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DRUNTIME",
        "-Wall",
        "-Wno-pointer-sign",
        "-Wno-parentheses",
    };

    const tads2_cpp_flags: []const []const u8 = if (is_wasm) &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DRUNTIME",
        "-Wall",
        "-std=c++11",
        "-fno-exceptions",
        "-fno-rtti",
        "-Wno-deprecated-register",
        "-D_WASI_EMULATED_SIGNAL",
        "-mllvm", "-wasm-enable-sjlj",
        "-mllvm", "-wasm-use-legacy-eh=false",
    } else &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DRUNTIME",
        "-Wall",
        "-std=c++11",
        "-Wno-deprecated-register",
    };

    // TADS 2 entry point
    exe.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"tads2_glk.c"},
        .flags = tads2_c_flags,
    });

    // TADS Glk interface layer (C files)
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/glk"),
        .files = &.{
            "memicmp.c",  "osbuffer.c", "osextra.c",  "osglk.c",
            "osglkban.c", "osmisc.c",   "osparse.c",  "t2askf.c",
            "t2indlg.c",
        },
        .flags = tads2_c_flags,
    });

    // osportable.cc - shared OS utility functions (C++ file but C-compatible interface).
    // Needs POSIX stub macros on WASI (dup, geteuid, etc.)
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/glk"),
        .files = &.{"osportable.cc"},
        .flags = if (is_wasm) &.{
            "-DGLK",       "-DGLK_TIMERS",  "-DGLK_UNICODE",
            "-DRUNTIME",   "-Wall",         "-std=c++11",
            "-fno-exceptions", "-fno-rtti", "-Wno-deprecated-register",
            "-D_WASI_EMULATED_SIGNAL",
            "-Ddup(x)=(-1)",
            "-Dgeteuid()=((unsigned)0)",
            "-Dgetegid()=((unsigned)0)",
            "-Dgetgroups(a,b)=(0)",
            "-mllvm", "-wasm-enable-sjlj",
            "-mllvm", "-wasm-use-legacy-eh=false",
        } else tads2_cpp_flags,
    });

    // Shared charmap/UTF-8 utilities from tads3/ (used by osportable.cc for character conversion).
    // Needs TC_TARGET_T3 and VMGLOB_STRUCT defines for tads3 header compatibility.
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/tads3"),
        .files = &.{ "charmap.cpp", "utf8.cpp" },
        .flags = if (is_wasm) &.{
            "-DGLK",        "-DGLK_UNICODE",   "-DRUNTIME",
            "-DTC_TARGET_T3", "-DVMGLOB_STRUCT",
            "-Wall",        "-std=c++11",      "-fno-exceptions", "-fno-rtti",
            "-D_WASI_EMULATED_SIGNAL",
            "-mllvm", "-wasm-enable-sjlj",
            "-mllvm", "-wasm-use-legacy-eh=false",
        } else &.{
            "-DGLK",        "-DGLK_UNICODE",   "-DRUNTIME",
            "-DTC_TARGET_T3", "-DVMGLOB_STRUCT",
            "-Wall",        "-std=c++11",
        },
    });

    // TADS 2 runtime (C)
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/tads2"),
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
        .flags = tads2_c_flags,
    });

    // WASI compatibility stubs (dup, geteuid, etc.)
    if (is_wasm) {
        exe.addCSourceFiles(.{
            .root = b.path("src"),
            .files = &.{"tads_compat.c"},
            .flags = &.{"-D_WASI_EMULATED_SIGNAL"},
        });
    }

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/tads/glk"));
    exe.addIncludePath(b.path("../garglk/terps/tads/tads2"));
    // tads3 include path needed for vmvsn.h and charmap.h (used by osglk.c and osportable.cc)
    exe.addIncludePath(b.path("../garglk/terps/tads/tads3"));
    exe.linkLibCpp();

    if (is_wasm) {
        addWasiSetjmp(exe, b);
    }

    return exe;
}

fn buildTads3(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    // TADS 3 is C++. Uses setjmp/longjmp for error handling (not C++ exceptions).
    const tads3_target = if (target.result.cpu.arch == .wasm32)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        })
    else
        target;

    const is_wasm = tads3_target.result.cpu.arch == .wasm32;

    const exe = b.addExecutable(.{
        .name = "tads3",
        .root_module = b.createModule(.{ .target = tads3_target, .optimize = optimize }),
    });

    const tads3_c_flags: []const []const u8 = if (is_wasm) &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DTC_TARGET_T3",
        "-DRUNTIME",
        "-DVMGLOB_STRUCT",
        "-Wall",
        "-Wno-pointer-sign",
        "-Wno-parentheses",
        "-D_WASI_EMULATED_SIGNAL",
        "-mllvm", "-wasm-enable-sjlj",
        "-mllvm", "-wasm-use-legacy-eh=false",
    } else &.{
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

    const tads3_cpp_flags: []const []const u8 = if (is_wasm) &.{
        "-DGLK",
        "-DGLK_TIMERS",
        "-DGLK_UNICODE",
        "-DTC_TARGET_T3",
        "-DRUNTIME",
        "-DVMGLOB_STRUCT",
        "-DLTC_SMALL_CODE",
        "-Wall",
        "-std=c++11",
        "-fno-exceptions",
        "-fno-rtti",
        "-Wno-deprecated-register",
        "-Wno-logical-not-parentheses",
        "-Wno-pointer-sign",
        "-Wno-string-concatenation",
        "-D_WASI_EMULATED_SIGNAL",
        "-mllvm", "-wasm-enable-sjlj",
        "-mllvm", "-wasm-use-legacy-eh=false",
    } else &.{
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

    // TADS 3 entry point
    exe.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"tads3_glk.cpp"},
        .flags = tads3_cpp_flags,
    });

    // TADS Glk interface layer (C files shared with TADS 2)
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/glk"),
        .files = &.{
            "memicmp.c",  "osbuffer.c", "osextra.c",  "osglk.c",
            "osglkban.c", "osmisc.c",   "osparse.c",
        },
        .flags = tads3_c_flags,
    });

    // TADS 3 Glk C++ files
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/glk"),
        .files = &.{
            "t3askf.cpp", "t3indlg.cpp", "vmuni_cs.cpp",
        },
        .flags = tads3_cpp_flags,
    });

    // osportable.cc needs POSIX stub macros on WASI (dup, geteuid, etc.)
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/glk"),
        .files = &.{"osportable.cc"},
        .flags = if (is_wasm) &.{
            "-DGLK",       "-DGLK_TIMERS",  "-DGLK_UNICODE", "-DTC_TARGET_T3",
            "-DRUNTIME",   "-DVMGLOB_STRUCT", "-Wall",        "-std=c++11",
            "-fno-exceptions", "-fno-rtti", "-Wno-deprecated-register",
            "-D_WASI_EMULATED_SIGNAL",
            "-Ddup(x)=(-1)",
            "-Dgeteuid()=((unsigned)0)",
            "-Dgetegid()=((unsigned)0)",
            "-Dgetgroups(a,b)=(0)",
            "-mllvm", "-wasm-enable-sjlj",
            "-mllvm", "-wasm-use-legacy-eh=false",
        } else tads3_cpp_flags,
    });

    // Shared OS utility functions from tads2/ (platform abstraction, not game engine)
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/tads2"),
        .files = &.{
            "osifc.c",    "osnoui.c",   "osrestad.c",
            "osstzprs.c", "ostzposix.c",
        },
        .flags = tads3_c_flags,
    });

    // TADS 3 VM (C++)
    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/tads/tads3"),
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
        .flags = tads3_cpp_flags,
    });

    // WASI compatibility stubs (dup, geteuid, etc.)
    if (is_wasm) {
        exe.addCSourceFiles(.{
            .root = b.path("src"),
            .files = &.{"tads_compat.c"},
            .flags = &.{"-D_WASI_EMULATED_SIGNAL"},
        });
    }

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/tads/glk"));
    // tads2 include path needed for os.h, trd.h (used by GLK layer)
    exe.addIncludePath(b.path("../garglk/terps/tads/tads2"));
    exe.addIncludePath(b.path("../garglk/terps/tads/tads3"));
    exe.linkLibCpp();

    if (is_wasm) {
        addWasiSetjmp(exe, b);
    }

    return exe;
}

// ============================================================================
// Simple interpreters (no setjmp/longjmp)
// ============================================================================

fn buildAgility(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "agility",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/agility"),
        .files = &.{
            "agtread.c",    "gamedata.c",   "util.c",       "agxfile.c",
            "auxfile.c",    "filename.c",   "parser.c",     "exec.c",
            "runverb.c",    "metacommand.c", "savegame.c",  "debugcmd.c",
            "agil.c",       "token.c",      "disassemble.c", "object.c",
            "interface.c",  "os_glk.c",
        },
        .flags = &.{
            "-DGLK",
            "-DGARGLK",
            "-D_XOPEN_SOURCE=600",
            "-D_WASI_EMULATED_SIGNAL",
            "-Wall",
            "-Wno-pointer-sign",
            "-Wno-unused-variable",
        },
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/agility"));

    return exe;
}

fn buildJacl(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "jacl",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const is_wasi = target.result.os.tag == .wasi;

    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/jacl"),
        .files = &.{
            "jacl.c",       "glk_startup.c", "findroute.c",  "interpreter.c",
            "loader.c",     "glk_saver.c",   "logging.c",    "parser.c",
            "display.c",    "utils.c",       "jpp.c",        "resolvers.c",
            "errors.c",     "encapsulate.c", "libcsv.c",
        },
        .flags = if (is_wasi) &.{
            "-DGLK",
            "-DGARGLK",
            // WASI doesn't support file locking - provide stub constants
            "-DF_SETLK=6",
            "-DF_RDLCK=0",
            "-DF_WRLCK=1",
            "-DF_UNLCK=2",
            "-D_XOPEN_SOURCE=600",
            "-D_WASI_EMULATED_SIGNAL",
            "-D_WASI_EMULATED_PROCESS_CLOCKS",
            "-Wall",
            "-Wno-parentheses-equality",
            "-Wno-macro-redefined",
            "-Wno-unused-variable",
        } else &.{
            "-DGLK",
            "-DGARGLK",
            "-D_XOPEN_SOURCE=600",
            "-Wall",
            "-Wno-parentheses-equality",
        },
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/jacl"));

    // Link emulated process clocks for WASI
    if (is_wasi) {
        exe.linkSystemLibrary("wasi-emulated-process-clocks");
    }

    return exe;
}

fn buildLevel9(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "level9",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/level9"),
        .files = &.{ "bitmap.c", "level9.c" },
        .flags = &.{
            "-DBITMAP_DECODER",
            "-DNEED_STRICMP_PROTOTYPE",
            "-Dstricmp=gln_strcasecmp",
            "-Dstrnicmp=gln_strncasecmp",
            "-D_WASI_EMULATED_SIGNAL",
            "-Wall",
            "-Wno-switch",
        },
    });

    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/level9/Glk"),
        .files = &.{"glk.c"},
        .flags = &.{
            "-DBITMAP_DECODER",
            "-DNEED_STRICMP_PROTOTYPE",
            "-Dstricmp=gln_strcasecmp",
            "-Dstrnicmp=gln_strncasecmp",
            "-D_WASI_EMULATED_SIGNAL",
            "-Wall",
        },
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/level9"));

    return exe;
}

fn buildMagnetic(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "magnetic",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/magnetic/Generic"),
        .files = &.{"emu.c"},
        .flags = &.{
            "-DMAGNETIC_GLKUNIX",
            "-D_WASI_EMULATED_SIGNAL",
            "-Wall",
            "-Wno-pointer-sign",
        },
    });

    exe.addCSourceFiles(.{
        .root = b.path("../garglk/terps/magnetic/Glk"),
        .files = &.{"glk.c"},
        .flags = &.{
            "-DMAGNETIC_GLKUNIX",
            "-D_WASI_EMULATED_SIGNAL",
            "-Wall",
            "-Wno-pointer-sign",
        },
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/magnetic/Generic"));

    return exe;
}

// ============================================================================
// Interpreters requiring setjmp/longjmp (WASM exception handling)
// ============================================================================

fn buildAdvsys(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const advsys_target = if (target.result.cpu.arch == .wasm32)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        })
    else
        target;

    const exe = b.addExecutable(.{
        .name = "advsys",
        .root_module = b.createModule(.{ .target = advsys_target, .optimize = optimize }),
    });

    const advsys_files = &[_][]const u8{
        "advmsg.c",  "advtrm.c",  "advprs.c",  "advdbs.c",
        "advint.c",  "advjunk.c", "advexe.c",  "glkstart.c",
    };

    if (advsys_target.result.cpu.arch == .wasm32) {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/advsys"),
            .files = advsys_files,
            .flags = &.{
                "-D_WASI_EMULATED_SIGNAL",
                "-Wall",
                "-Wno-parentheses",
                "-mllvm", "-wasm-enable-sjlj",
                "-mllvm", "-wasm-use-legacy-eh=false",
            },
        });
        addWasiSetjmp(exe, b);
    } else {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/advsys"),
            .files = advsys_files,
            .flags = &.{
                "-D_WASI_EMULATED_SIGNAL",
                "-Wall",
                "-Wno-parentheses",
            },
        });
    }

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/advsys"));

    return exe;
}

fn buildAlan2(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const alan2_target = if (target.result.cpu.arch == .wasm32)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        })
    else
        target;

    const exe = b.addExecutable(.{
        .name = "alan2",
        .root_module = b.createModule(.{ .target = alan2_target, .optimize = optimize }),
    });

    const alan2_files = &[_][]const u8{
        "arun.c",       "main.c",     "debug.c",    "args.c",
        "exe.c",        "inter.c",    "parse.c",    "rules.c",
        "stack.c",      "decode.c",   "term.c",     "reverse.c",
        "readline.c",   "params.c",   "sysdep.c",   "glkstart.c",
        "glkio.c",      "alan.version.c",
    };

    // REVERSED macro for little-endian systems
    const base_flags = &[_][]const u8{
        "-DGLK",
        "-DGARGLK",
        "-DREVERSED", // Little-endian
        "-D__unix__", // For WASI compatibility with unix-style code paths
        "-D_XOPEN_SOURCE=600",
        "-D_WASI_EMULATED_SIGNAL",
        "-Wall",
        "-Wno-dangling-else",
    };

    if (alan2_target.result.cpu.arch == .wasm32) {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/alan2"),
            .files = alan2_files,
            .flags = base_flags ++ &[_][]const u8{
                "-mllvm", "-wasm-enable-sjlj",
                "-mllvm", "-wasm-use-legacy-eh=false",
            },
        });
        addWasiSetjmp(exe, b);
    } else {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/alan2"),
            .files = alan2_files,
            .flags = base_flags,
        });
    }

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/alan2"));

    return exe;
}

fn buildAlan3(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const alan3_target = if (target.result.cpu.arch == .wasm32)
        b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        })
    else
        target;

    const exe = b.addExecutable(.{
        .name = "alan3",
        .root_module = b.createModule(.{ .target = alan3_target, .optimize = optimize }),
    });

    const alan3_files = &[_][]const u8{
        "alan.version.c", "act.c",        "actor.c",      "args.c",
        "arun.c",         "attribute.c",  "checkentry.c", "class.c",
        "converter.c",    "current.c",    "debug.c",      "decode.c",
        "dictionary.c",   "event.c",      "exe.c",        "fnmatch.c",
        "glkio.c",        "glkstart.c",   "instance.c",   "inter.c",
        "lists.c",        "literal.c",    "main.c",       "memory.c",
        "msg.c",          "options.c",    "output.c",     "params.c",
        "parse.c",        "readline.c",   "reverse.c",    "rules.c",
        "save.c",         "scan.c",       "score.c",      "set.c",
        "stack.c",        "state.c",      "syntax.c",     "sysdep.c",
        "syserr.c",       "term.c",       "types.c",      "utils.c",
        "word.c",         "compatibility.c", "AltInfo.c", "Container.c",
        "Location.c",     "ParameterPosition.c", "StateStack.c",
    };

    const base_flags = &[_][]const u8{
        "-DGLK",
        "-DGARGLK",
        "-DHAVE_GARGLK",
        "-DBUILD=0",
        "-D_XOPEN_SOURCE=600",
        "-D_WASI_EMULATED_SIGNAL",
        "-Wall",
    };

    if (alan3_target.result.cpu.arch == .wasm32) {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/alan3"),
            .files = alan3_files,
            .flags = base_flags ++ &[_][]const u8{
                "-mllvm", "-wasm-enable-sjlj",
                "-mllvm", "-wasm-use-legacy-eh=false",
            },
        });
        addWasiSetjmp(exe, b);
    } else {
        exe.addCSourceFiles(.{
            .root = b.path("../garglk/terps/alan3"),
            .files = alan3_files,
            .flags = base_flags,
        });
    }

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("../garglk/terps/alan3"));

    return exe;
}

// Helper to link wasi-sdk's libsetjmp for WASM exception handling
fn addWasiSetjmp(exe: *std.Build.Step.Compile, b: *std.Build) void {
    const wasi_sdk_path = std.process.getEnvVarOwned(b.allocator, "WASI_SDK_PATH") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound) {
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

fn buildFizmo(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "fizmo",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

    const fizmo_flags: []const []const u8 = &.{
        "-DDISABLE_BABEL",
        "-DDISABLE_CONFIGFILES",
        "-DDISABLE_FILELIST",
        "-DDISABLE_COMMAND_HISTORY",
        "-Wall",
        "-Wno-unused-but-set-variable",
        "-Wno-unused-variable",
    };

    // Core interpreter sources (libfizmo)
    exe.addCSourceFiles(.{
        .root = b.path("../libfizmo/src/interpreter"),
        .files = &.{
            "babel.c",
            "blockbuf.c",
            "blorb.c",
            "cmd_hst.c",
            "config.c",
            // debugger.c excluded - uses sockets, not available in WASI
            "filelist.c",
            "fizmo.c",
            "history.c",
            "hyphenation.c",
            "iff.c",
            "mathemat.c",
            "misc.c",
            "mt19937ar.c",
            "object.c",
            "output.c",
            "property.c",
            "routine.c",
            "savegame.c",
            "sound.c",
            "stack.c",
            "streams.c",
            "table.c",
            "text.c",
            "undo.c",
            "variable.c",
            "wordwrap.c",
            "zpu.c",
        },
        .flags = fizmo_flags,
    });

    // Tools library (libfizmo)
    exe.addCSourceFiles(.{
        .root = b.path("../libfizmo/src/tools"),
        .files = &.{
            "filesys.c",
            "filesys_c.c",
            "i18n.c",
            "list.c",
            "stringmap.c",
            "tracelog.c",
            "types.c",
            "z_ucs.c",
        },
        .flags = fizmo_flags,
    });

    // Locales (libfizmo)
    exe.addCSourceFiles(.{
        .root = b.path("../libfizmo/src/locales"),
        .files = &.{
            "libfizmo_locales.c",
            "locale_data.c",
        },
        .flags = fizmo_flags,
    });

    // Glk interface (libglkif)
    exe.addCSourceFiles(.{
        .root = b.path("../libglkif/src/glk_interface"),
        .files = &.{
            "glk_blorb_if.c",
            "glk_filesys_if.c",
            "glk_interface.c",
            "glk_screen_if.c",
        },
        .flags = fizmo_flags,
    });

    // Glk interface locales (libglkif)
    exe.addCSourceFiles(.{
        .root = b.path("../libglkif/src/locales"),
        .files = &.{
            "libglkif_locales.c",
            "locale_data.c",
        },
        .flags = fizmo_flags,
    });

    // Glue + compatibility stubs
    exe.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "fizmo_glk.c",
            "fizmo_compat.c",
        },
        .flags = fizmo_flags,
    });

    exe.addIncludePath(b.path("../libfizmo/src"));
    exe.addIncludePath(b.path("../libglkif/src"));

    addGlkSupport(exe, b, wasi_glk, true);

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
