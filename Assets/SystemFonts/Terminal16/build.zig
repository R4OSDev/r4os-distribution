const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "terminal16_fontgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
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
    r4f_writer.addImport("r4f_format", r4f_format);
    exe.root_module.addImport("r4f_writer", r4f_writer);

    const run_cmd = b.addRunArtifact(exe);
    const output = run_cmd.addOutputFileArg("TERMINAL16.R4F");
    const install_output = b.addInstallFile(output, "TERMINAL16.R4F");
    b.getInstallStep().dependOn(&install_output.step);
}
