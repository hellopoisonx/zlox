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
    const vm_mod = b.addModule("czlox", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
    });

    const exe_vm = b.addExecutable(.{
        .name = "czlox",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vm/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "czlox", .module = vm_mod },
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
    if (b.args) |args| {
        run_treewalk_cmd.addArgs(args);
    }
    const run_treewalk_step = b.step("run", "Run the tree-walk interpreter (zlox)");
    run_treewalk_step.dependOn(&run_treewalk_cmd.step);

    // `zig build run-vm` -> 运行 Bytecode VM (czlox)
    const run_vm_cmd = b.addRunArtifact(exe_vm);
    run_vm_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_vm_cmd.addArgs(args);
    }
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
