const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("srf", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/srf.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "srf",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "srf" is the name you will use in your source code to
                // import this module (e.g. `@import("srf")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "srf", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.

    // Benchmark step
    const benchmark_step = b.step("benchmark", "Run benchmarks with hyperfine");
    const benchmark_optimize = if (optimize == .Debug) .ReleaseSafe else optimize;
    const benchmark_record_count = 100_000;
    const include_jsonl = b.option(bool, "benchmark-jsonl", "Include JSONL in benchmarks (slow)") orelse false;

    // Check for hyperfine
    const check_hyperfine = b.addSystemCommand(&.{ "sh", "-c", "command -v hyperfine >/dev/null 2>&1 || (echo 'Error: hyperfine not found. Install it with: cargo install hyperfine' >&2 && exit 1)" });
    benchmark_step.dependOn(&check_hyperfine.step);

    // Build test data generator
    const gen_exe = b.addExecutable(.{
        .name = "generate_test_data",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate_test_data.zig"),
            .target = target,
            .optimize = benchmark_optimize,
        }),
    });
    const install_gen = b.addInstallArtifact(gen_exe, .{});
    check_hyperfine.step.dependOn(&install_gen.step);

    // Rebuild main executable with benchmark optimization
    const benchmark_exe = b.addExecutable(.{
        .name = "srf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = benchmark_optimize,
            .imports = &.{
                .{ .name = "srf", .module = mod },
            },
        }),
    });
    const install_benchmark_exe = b.addInstallArtifact(benchmark_exe, .{});
    check_hyperfine.step.dependOn(&install_benchmark_exe.step);

    const run_benchmark = BenchmarkStep.create(b, .{
        .gen_exe = gen_exe,
        .srf_exe = benchmark_exe,
        .record_count = benchmark_record_count,
        .include_jsonl = include_jsonl,
    });
    run_benchmark.step.dependOn(&check_hyperfine.step);
    benchmark_step.dependOn(&run_benchmark.step);
}

const BenchmarkStep = struct {
    step: std.Build.Step,
    gen_exe: *std.Build.Step.Compile,
    srf_exe: *std.Build.Step.Compile,
    record_count: usize,
    include_jsonl: bool,

    pub fn create(owner: *std.Build, options: struct {
        gen_exe: *std.Build.Step.Compile,
        srf_exe: *std.Build.Step.Compile,
        record_count: usize,
        include_jsonl: bool,
    }) *BenchmarkStep {
        const self = owner.allocator.create(BenchmarkStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "run benchmark",
                .owner = owner,
                .makeFn = make,
            }),
            .gen_exe = options.gen_exe,
            .srf_exe = options.srf_exe,
            .record_count = options.record_count,
            .include_jsonl = options.include_jsonl,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const b = step.owner;
        const self: *BenchmarkStep = @fieldParentPtr("step", step);

        const gen_path = b.getInstallPath(.bin, self.gen_exe.name);
        const exe_path = b.getInstallPath(.bin, self.srf_exe.name);
        const count_str = b.fmt("{d}", .{self.record_count});

        const formats = [_]struct { name: []const u8, ext: []const u8 }{
            .{ .name = "srf-compact", .ext = "srf" },
            .{ .name = "srf-long", .ext = "srf" },
            .{ .name = "jsonl", .ext = "jsonl" },
            .{ .name = "json", .ext = "json" },
        };

        var test_files: [4][]const u8 = undefined;
        for (formats, 0..) |fmt, i| {
            // Create hash from format name and record count
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(fmt.name);
            hasher.update(count_str);
            const hash = hasher.final();

            const hash_str = b.fmt("{x}", .{hash});
            const cache_dir = b.cache_root.join(b.allocator, &.{ "o", hash_str }) catch @panic("OOM");
            std.fs.cwd().makePath(cache_dir) catch {};

            const filename = b.fmt("test-{s}.{s}", .{ fmt.name, fmt.ext });
            const filepath = b.pathJoin(&.{ cache_dir, filename });
            test_files[i] = filepath;

            // Check if file exists
            if (std.fs.cwd().access(filepath, .{})) {
                continue; // File exists, skip generation
            } else |_| {}

            // Generate file
            var child = std.process.Child.init(&.{ gen_path, fmt.name, count_str }, b.allocator);
            child.stdout_behavior = .Pipe;
            try child.spawn();

            const output = try child.stdout.?.readToEndAlloc(b.allocator, 100 * 1024 * 1024);
            defer b.allocator.free(output);

            const term = try child.wait();
            if (term != .Exited or term.Exited != 0) return error.GenerationFailed;

            try std.fs.cwd().writeFile(.{ .sub_path = filepath, .data = output });
        }

        // Run hyperfine
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(b.allocator);

        try argv.appendSlice(b.allocator, &.{ "hyperfine", "-w", "2" });
        try argv.append(b.allocator, b.fmt("{s} srf <{s}", .{ exe_path, test_files[0] }));
        try argv.append(b.allocator, b.fmt("{s} srf <{s}", .{ exe_path, test_files[1] }));
        try argv.append(b.allocator, b.fmt("{s} json <{s}", .{ exe_path, test_files[3] }));
        if (self.include_jsonl) {
            try argv.append(b.allocator, b.fmt("{s} jsonl <{s}", .{ exe_path, test_files[2] }));
        }

        var child = std.process.Child.init(argv.items, b.allocator);

        // We need to lock stderror so hyperfine can output progress in place
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();

        try child.spawn();
        const term = try child.wait();

        if (term != .Exited or term.Exited != 0)
            return error.BenchmarkFailed;
    }
};
