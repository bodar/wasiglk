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

    // Build all interpreters
    // Note: bocfel requires fstream (not available in WASI libc++)
    const interpreters = .{
        .{ "glulxe", "Build Glulxe interpreter", buildGlulxe },
        .{ "git", "Build Git interpreter", buildGit },
        .{ "hugo", "Build Hugo interpreter", buildHugo },
        // .{ "bocfel", "Build Bocfel interpreter", buildBocfel },
    };

    inline for (interpreters) |info| {
        const exe = info[2](b, target, optimize, wasi_glk);
        const install = b.addInstallArtifact(exe, .{});
        b.step(info[0], info[1]).dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
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

fn buildBocfel(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, wasi_glk: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "bocfel",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });

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
        .flags = &.{
            "-DZTERP_GLK",             "-DZTERP_GLK_BLORB",
            "-DZTERP_GLK_NO_STDIO",    "-DZTERP_GLK_UNIX",
            "-DZTERP_NO_SAFETY_CHECKS", "-Wall",
            "-std=c++14",              "-fexceptions", // Required for save/restore
            "-D_WASI_EMULATED_SIGNAL",
        },
    });

    addGlkSupport(exe, b, wasi_glk, false);
    exe.addIncludePath(b.path("garglk/terps/bocfel"));
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
