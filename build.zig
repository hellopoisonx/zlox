const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==========================================
    // 1. Tree-Walk Interpreter (zlox)
    // ==========================================
    const treewalk_mod = b.addModule("zlox", .{
        .root_source_file = b.path("src/treewalk/root.zig"),
        .target = target,
    });

    const exe_treewalk = b.addExecutable(.{
        .name = "zlox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/treewalk/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlox", .module = treewalk_mod },
            },
        }),
    });
    b.installArtifact(exe_treewalk);

    // ==========================================
    // 2. Bytecode VM Interpreter (czlox)
    // ==========================================

    const trace_execution = b.option(bool, "trace-execution", "Enable opcode trace logging in VM") orelse false;
    const print_code = b.option(bool, "print-code", "Enable chunk disassembly after compiling") orelse false;
    const stress_gc = b.option(bool, "stress-gc", "Stress test garbage collector") orelse false;
    const log_gc = b.option(bool, "log-gc", "Enable garbage collection logging") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "trace_execution", trace_execution);
    options.addOption(bool, "print_code", print_code);
    options.addOption(bool, "stress_gc", stress_gc);
    options.addOption(bool, "log_gc", log_gc);

    const options_mod = options.createModule();

    const vm_mod = b.addModule("czlox", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });

    const exe_vm = b.addExecutable(.{
        .name = "czlox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "czlox", .module = vm_mod },
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });
    b.installArtifact(exe_vm);

    // ==========================================
    // 3. 运行步骤 (Run Steps)
    // ==========================================
    // `zig build run` -> 运行 Tree-walk (zlox)
    const run_treewalk_cmd = b.addRunArtifact(exe_treewalk);
    run_treewalk_cmd.step.dependOn(b.getInstallStep());
    run_treewalk_cmd.addPassthruArgs();
    const run_treewalk_step = b.step("run", "Run the tree-walk interpreter (zlox)");
    run_treewalk_step.dependOn(&run_treewalk_cmd.step);

    // `zig build run-vm` -> 运行 Bytecode VM (czlox)
    const run_vm_cmd = b.addRunArtifact(exe_vm);
    run_vm_cmd.step.dependOn(b.getInstallStep());
    run_vm_cmd.addPassthruArgs();
    const run_vm_step = b.step("run-vm", "Run the bytecode VM (czlox)");
    run_vm_step.dependOn(&run_vm_cmd.step);

    // ==========================================
    // 4. 测试步骤 (Test Steps)
    // ==========================================
    const test_step = b.step("test", "Run all unit tests");

    const treewalk_mod_tests = b.addTest(.{
        .root_module = treewalk_mod,
    });
    const run_treewalk_mod_tests = b.addRunArtifact(treewalk_mod_tests);

    const treewalk_exe_tests = b.addTest(.{
        .root_module = exe_treewalk.root_module,
    });
    const run_treewalk_exe_tests = b.addRunArtifact(treewalk_exe_tests);

    const vm_mod_tests = b.addTest(.{
        .root_module = vm_mod,
    });
    const run_vm_mod_tests = b.addRunArtifact(vm_mod_tests);

    const vm_exe_tests = b.addTest(.{
        .root_module = exe_vm.root_module,
    });
    const run_vm_exe_tests = b.addRunArtifact(vm_exe_tests);

    test_step.dependOn(&run_treewalk_mod_tests.step);
    test_step.dependOn(&run_treewalk_exe_tests.step);
    test_step.dependOn(&run_vm_mod_tests.step);
    test_step.dependOn(&run_vm_exe_tests.step);
}
