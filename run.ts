#!/usr/bin/env ./bootstrap.sh
import {$, spawn, file, write, Glob} from "bun";
import {dirname, join} from "path";

process.env.FORCE_COLOR = "1";

export async function version() {
    const branch = process.env.GITHUB_REF_NAME || (await $`git rev-parse --abbrev-ref HEAD`.quiet()).text().trim();
    const buildNumber = process.env.GITHUB_RUN_NUMBER || new Date().toISOString().replace(/[-:T]/g, '').split('.')[0];
    const revisions = (await $`git rev-list --count ${branch}`.quiet()).text().trim();
    const version = `0.${revisions}.${buildNumber}`;

    console.log(`version: ${version}`);
    return version;
}

export async function clean() {
    await $`rm -rf packages/server/zig-out packages/server/zig-cache packages/server/.zig-cache packages/client/wasm`;
    await $`bun install --ignore-scripts`.quiet();
}

export async function check() {
    await $`bun run --bun tsgo --noEmit`;
}

export async function build(...args: string[]) {
    await testZig();
    await buildZig(...args);
    await optimize();
}

// Build Zig interpreters (server package)
export async function buildZig(...args: string[]) {
    // Default to ReleaseSmall for WASM size optimization
    const optimize = args.includes('-Doptimize=') ? [] : ['-Doptimize=ReleaseSmall'];
    await $`zig build --build-file packages/server/build.zig --prefix packages/server/zig-out ${optimize} ${args}`;
}

// Optimize WASM binaries with Binaryen wasm-opt
export async function optimize() {
    const glob = new Glob("packages/server/zig-out/bin/*.wasm");
    const wasmFiles = Array.from(glob.scanSync("."));

    if (wasmFiles.length === 0) {
        console.log("No WASM files to optimize");
        return;
    }

    console.log(`Optimizing ${wasmFiles.length} WASM files with wasm-opt...`);
    const wasmOpt = "./node_modules/.bin/wasm-opt";

    await Promise.all(wasmFiles.map(async (f) => {
        const before = Bun.file(f).size;
        await $`${wasmOpt} -Oz \
            --enable-bulk-memory \
            --enable-exception-handling \
            --enable-nontrapping-float-to-int \
            --enable-sign-ext \
            --enable-mutable-globals \
            --enable-reference-types \
            --enable-typed-function-references \
            ${f} -o ${f}`.quiet();
        const after = Bun.file(f).size;
        const saved = before - after;
        const percent = Math.round(saved * 100 / before);
        console.log(`  ${f.split('/').pop()}: ${before} -> ${after} (${percent}% smaller)`);
    }));
}

// Copy WASM binaries into client package for publishing
export async function bundle() {
    const wasmDir = "packages/client/wasm";
    await $`mkdir -p ${wasmDir}`;

    const glob = new Glob("packages/server/zig-out/bin/*.wasm");
    const wasmFiles = Array.from(glob.scanSync("."));

    if (wasmFiles.length === 0) {
        throw new Error("No WASM files found - run build first");
    }

    for (const f of wasmFiles) {
        const name = f.split('/').pop()!;
        await $`cp ${f} ${wasmDir}/${name}`;
    }

    console.log(`Bundled ${wasmFiles.length} WASM files into ${wasmDir}`);
}

// Run Zig unit tests (server package)
export async function testZig(...args: string[]) {
    await $`zig build --build-file packages/server/build.zig test ${args}`;
}

// Run client unit tests
export async function testClient() {
    await $`bun test --cwd packages/client`;
}

// Run server regression tests (interpreter output validation)
export async function testServer(...args: string[]) {
    await $`bun packages/server/tests/regtest.ts ${args}`;
}

// Run all tests (Zig + client unit tests + E2E)
export async function test(...args: string[]) {
    await testZig();
    await testClient();
    await testE2E(...args);
}

// Run E2E browser tests
export async function testE2E(...args: string[]) {
    // Start the dev server in background
    const server = spawn({
        cmd: ['bun', 'run', 'packages/example/serve.ts'],
        stdout: 'inherit',
        stderr: 'inherit',
    });

    // Wait for server to be ready
    await new Promise(resolve => setTimeout(resolve, 1000));

    try {
        // Playwright's test runner requires Node - bunx has compatibility issues
        await $`npx playwright test --config=packages/example/playwright.config.js ${args}`;
    } finally {
        server.kill();
    }
}

// Run tests with browser visible (useful for debugging)
export async function testHeaded(...args: string[]) {
    await test('--headed', ...args);
}

// Run the example/demo
export async function demo() {
    await $`bun run packages/example/serve.ts`;
}

// Alias for demo
export async function serve() {
    await demo();
}

/**
 * Prepares the client package for JSR publishing by:
 * 1. Generating a jsr.json config file
 * 2. Replacing workspace: dependencies with actual version numbers
 *
 * Returns info needed to restore workspace dependencies after publish.
 */
export async function jsr(): Promise<{ packageFile: string; depName: string; originalVersion: string }[]> {
    const v = await version();
    const modifications: { packageFile: string; depName: string; originalVersion: string }[] = [];

    for await (const f of new Glob("packages/client/package.json").scan(".")) {
        const packageJsonFile = file(f);
        const packageJson = await packageJsonFile.json();
        const parent = dirname(f!);
        const jsrFile = file(join(parent, 'jsr.json'));

        if (packageJson.dependencies) {
            for (const [depName, depVersion] of Object.entries(packageJson.dependencies)) {
                if (typeof depVersion === 'string' && depVersion.startsWith('workspace:')) {
                    modifications.push({ packageFile: f, depName, originalVersion: depVersion });
                    packageJson.dependencies[depName] = v;
                }
            }
            await write(packageJsonFile, JSON.stringify(packageJson, null, 2));
        }

        const jsrConfig: any = {
            name: packageJson.name,
            version: v,
            description: packageJson.description,
            exports: packageJson.exports,
            license: 'MIT'
        };

        if (packageJson.files) {
            jsrConfig.publish = {
                include: packageJson.files
            };
        }

        await write(jsrFile, JSON.stringify(jsrConfig, null, 2));
    }

    return modifications;
}

/**
 * Restores workspace: dependencies and removes jsr.json files after publishing.
 */
async function cleanupAfterPublish(modifications: { packageFile: string; depName: string; originalVersion: string }[]) {
    const byFile = new Map<string, { depName: string; originalVersion: string }[]>();
    for (const mod of modifications) {
        if (!byFile.has(mod.packageFile)) byFile.set(mod.packageFile, []);
        byFile.get(mod.packageFile)!.push(mod);
    }

    for (const [packageFile, mods] of byFile) {
        const packageJsonFile = file(packageFile);
        const packageJson = await packageJsonFile.json();
        for (const { depName, originalVersion } of mods) {
            packageJson.dependencies[depName] = originalVersion;
        }
        await write(packageJsonFile, JSON.stringify(packageJson, null, 2));
    }

    for await (const f of new Glob("packages/client/jsr.json").scan(".")) {
        await $`rm -f ${f}`.quiet();
    }
}

export async function publish(dryRun: string = "") {
    const modifications = await jsr();
    const isDryRun = dryRun === "--dry-run" || dryRun === "dry-run";
    const dryRunFlag = isDryRun ? ["--dry-run"] : [];
    try {
        await $`bunx jsr publish --allow-dirty --verbose ${dryRunFlag}`;
    } finally {
        await cleanupAfterPublish(modifications);
    }
}

export async function ci() {
    await clean();
    await check();
    await testZig();
    await testClient();
    await build();
    await bundle();
    await publish();
}

// Command dispatch - same pattern as bodar.ts
const commands: Record<string, Function> = {
    version, clean, check, build, buildZig, optimize, bundle,
    testZig, testClient, testServer, test, testE2E, testHeaded,
    demo, serve, jsr, publish, ci
};

const command = process.argv[2] || 'build';
const args = process.argv.slice(3);

const fn = commands[command];
if (fn) {
    try {
        await fn(...args);
    } catch (e: any) {
        console.error('Command failed:', command, ...args, e.message);
        process.exit(1);
    }
} else {
    const { exitCode } = await $`${command} ${args}`.nothrow();
    process.exit(exitCode);
}
