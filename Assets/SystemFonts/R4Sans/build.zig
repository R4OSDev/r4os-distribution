const std = @import("std");

const output_names = [_][]const u8{
    "R4SANS08.R4F",
    "R4SANS08B.R4F",
    "R4SANS12.R4F",
    "R4SANS12B.R4F",
    "R4SANS16.R4F",
    "R4SANS16B.R4F",
    "R4SANS24.R4F",
    "R4SANS24B.R4F",
    "R4SANS32.R4F",
    "R4SANS32B.R4F",
    "R4SANS40.R4F",
    "R4SANS40B.R4F",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "r4sans_fontgen",
        .root_module = rootModule(b, target, optimize),
    });
    addImports(b, exe.root_module, target, optimize);

    const run_cmd = b.addRunArtifact(exe);
    for (output_names) |name| {
        const output = run_cmd.addOutputFileArg(name);
        const install_output = b.addInstallFile(output, name);
        b.getInstallStep().dependOn(&install_output.step);
    }

    const tests = b.addTest(.{ .root_module = rootModule(b, target, optimize) });
    addImports(b, tests.root_module, target, optimize);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run R4 Sans generator tests");
    test_step.dependOn(&run_tests.step);
}

fn rootModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn addImports(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const r4f_format = b.createModule(.{
        .root_source_file = b.path("../../Libraries/R4FONT/Bindings/Zig/font_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    const r4f_writer = b.createModule(.{
        .root_source_file = b.path("../r4f_writer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const glyphs = b.createModule(.{
        .root_source_file = b.path("../Terminal8/src/glyphs.zig"),
        .target = target,
        .optimize = optimize,
    });
    r4f_writer.addImport("r4f_format", r4f_format);
    module.addImport("r4f_format", r4f_format);
    module.addImport("r4f_writer", r4f_writer);
    module.addImport("base_glyphs", glyphs);
}
