const std = @import("std");

// Emglken build.zig - Compile IF interpreters to WASM/WASI using Zig
//
// This is a proof-of-concept for compiling the C/C++ interpreters
// to WebAssembly with WASI support, targeting Cloudflare Workers
// and other WASI-compatible runtimes.

pub fn build(b: *std.Build) void {
    // Target wasm32-wasi for Cloudflare Workers compatibility
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const optimize = b.standardOptimizeOption(.{});

    // Build Glulxe interpreter (reference Glulx implementation)
    const glulxe = buildGlulxe(b, target, optimize);
    b.installArtifact(glulxe);

    // Build Git interpreter (optimized Glulx implementation)
    const git = buildGit(b, target, optimize);
    b.installArtifact(git);

    // Build Hugo interpreter
    const hugo = buildHugo(b, target, optimize);
    b.installArtifact(hugo);

    // Build Bocfel interpreter (Z-machine, C++)
    const bocfel = buildBocfel(b, target, optimize);
    b.installArtifact(bocfel);

    // Build Scare interpreter (ADRIFT/SCARE)
    const scare = buildScare(b, target, optimize);
    b.installArtifact(scare);
}

fn buildGlulxe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "glulxe",
        .target = target,
        .optimize = optimize,
    });

    // Glulxe source files
    const glulxe_sources = [_][]const u8{
        "accel.c",
        "debugger.c",
        "exec.c",
        "files.c",
        "float.c",
        "funcs.c",
        "gestalt.c",
        "glkop.c",
        "heap.c",
        "main.c",
        "operand.c",
        "osdepend.c",
        "profile.c",
        "search.c",
        "serial.c",
        "string.c",
        "vm.c",
        "unixstrt.c",
        "unixautosave.c",
    };

    exe.addCSourceFiles(.{
        .root = b.path("glulxe"),
        .files = &glulxe_sources,
        .flags = &.{
            "-DOS_UNIX",
            "-Wall",
            "-Wmissing-prototypes",
            "-Wno-unused",
            // WASI-specific flags
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    // Add WASI-Glk implementation
    exe.addCSourceFiles(.{
        .root = b.path("src/wasi-glk"),
        .files = &.{"wasi_glk.c"},
        .flags = &.{
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    exe.addIncludePath(b.path("glulxe"));
    exe.addIncludePath(b.path("src/wasi-glk"));

    // Link against WASI libc
    exe.linkLibC();

    return exe;
}

fn buildGit(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "git",
        .target = target,
        .optimize = optimize,
    });

    const git_sources = [_][]const u8{
        "accel.c",
        "compiler.c",
        "gestalt.c",
        "git.c",
        "glkop.c",
        "heap.c",
        "memory.c",
        "opcodes.c",
        "operands.c",
        "peephole.c",
        "savefile.c",
        "saveundo.c",
        "search.c",
        "terp.c",
        "git_unix.c",
    };

    exe.addCSourceFiles(.{
        .root = b.path("git"),
        .files = &git_sources,
        .flags = &.{
            "-DUSE_DIRECT_THREADING",
            "-DUSE_INLINE",
            "-Wall",
            "-Wno-int-conversion",
            "-Wno-pointer-sign",
            "-Wno-unused-but-set-variable",
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    // Add WASI-Glk implementation
    exe.addCSourceFiles(.{
        .root = b.path("src/wasi-glk"),
        .files = &.{"wasi_glk.c"},
        .flags = &.{
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    exe.addIncludePath(b.path("git"));
    exe.addIncludePath(b.path("src/wasi-glk"));
    exe.linkLibC();

    return exe;
}

fn buildHugo(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "hugo",
        .target = target,
        .optimize = optimize,
    });

    const hugo_source_files = [_][]const u8{
        "he.c",
        "heexpr.c",
        "hemisc.c",
        "heobject.c",
        "heparse.c",
        "heres.c",
        "herun.c",
        "heset.c",
        "stringfn.c",
    };

    const hugo_glk_files = [_][]const u8{
        "heglk.c",
        "heglkunix.c",
    };

    exe.addCSourceFiles(.{
        .root = b.path("hugo/source"),
        .files = &hugo_source_files,
        .flags = &.{
            "-DCOMPILE_V25",
            "-DGLK",
            "-DNO_KEYPRESS_CURSOR",
            "-DHUGO_INLINE=static inline",
            "-Wall",
            "-Wno-unused-but-set-variable",
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    exe.addCSourceFiles(.{
        .root = b.path("hugo/heglk"),
        .files = &hugo_glk_files,
        .flags = &.{
            "-DCOMPILE_V25",
            "-DGLK",
            "-DNO_KEYPRESS_CURSOR",
            "-DHUGO_INLINE=static inline",
            "-Wall",
            "-Wno-unused-but-set-variable",
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    // Add WASI-Glk implementation
    exe.addCSourceFiles(.{
        .root = b.path("src/wasi-glk"),
        .files = &.{"wasi_glk.c"},
        .flags = &.{
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    exe.addIncludePath(b.path("hugo/source"));
    exe.addIncludePath(b.path("hugo/heglk"));
    exe.addIncludePath(b.path("src/wasi-glk"));
    exe.linkLibC();

    return exe;
}

fn buildBocfel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "bocfel",
        .target = target,
        .optimize = optimize,
    });

    // Bocfel source files (C++)
    const bocfel_sources = [_][]const u8{
        "blorb.cpp",
        "branch.cpp",
        "dict.cpp",
        "glkautosave.cpp",
        "glkstart.cpp",
        "iff.cpp",
        "io.cpp",
        "mathop.cpp",
        "meta.cpp",
        "memory.cpp",
        "objects.cpp",
        "options.cpp",
        "osdep.cpp",
        "patches.cpp",
        "process.cpp",
        "random.cpp",
        "screen.cpp",
        "sound.cpp",
        "stack.cpp",
        "stash.cpp",
        "unicode.cpp",
        "util.cpp",
        "zoom.cpp",
        "zterp.cpp",
    };

    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/bocfel"),
        .files = &bocfel_sources,
        .flags = &.{
            "-DZTERP_GLK",
            "-DZTERP_GLK_BLORB",
            "-DZTERP_GLK_NO_STDIO",
            "-DZTERP_GLK_UNIX",
            "-DZTERP_NO_SAFETY_CHECKS",
            "-Wall",
            "-std=c++14",
            "-D_WASI_EMULATED_SIGNAL",
            // Disable exceptions for smaller WASM (use -fexceptions if needed)
            "-fno-exceptions",
        },
    });

    // Add WASI-Glk implementation
    exe.addCSourceFiles(.{
        .root = b.path("src/wasi-glk"),
        .files = &.{"wasi_glk.c"},
        .flags = &.{
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    exe.addIncludePath(b.path("garglk/terps/bocfel"));
    exe.addIncludePath(b.path("src/wasi-glk"));
    exe.linkLibC();
    exe.linkLibCpp();

    return exe;
}

fn buildScare(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "scare",
        .target = target,
        .optimize = optimize,
    });

    const scare_sources = [_][]const u8{
        "os_glk.c",
        "scdebug.c",
        "scevents.c",
        "scexpr.c",
        "scgamest.c",
        "scinterf.c",
        "sclibrar.c",
        "sclocale.c",
        "scmemos.c",
        "scnpcs.c",
        "scobjcts.c",
        "scparser.c",
        "scprintf.c",
        "scprops.c",
        "scresour.c",
        "screstrs.c",
        "scrunner.c",
        "scserial.c",
        "sctaffil.c",
        "sctafpar.c",
        "sctasks.c",
        "scutils.c",
        "scvars.c",
    };

    exe.addCSourceFiles(.{
        .root = b.path("garglk/terps/scare"),
        .files = &scare_sources,
        .flags = &.{
            "-Wall",
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    // Add WASI-Glk implementation
    exe.addCSourceFiles(.{
        .root = b.path("src/wasi-glk"),
        .files = &.{"wasi_glk.c"},
        .flags = &.{
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    exe.addIncludePath(b.path("garglk/terps/scare"));
    exe.addIncludePath(b.path("src/wasi-glk"));
    exe.linkLibC();

    return exe;
}
