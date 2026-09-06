const std = @import("std");

const system_font_names = [_][]const u8{
    "TERMINAL8.R4F",
    "TERMINAL16.R4F",
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

    const sdk_dependency = b.dependency("r4os_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const libraries_dependency = b.dependency("r4os_libraries", .{});
    const r4u_artifact = b.createModule(.{
        .root_source_file = sdk_dependency.path("r4os/r4u_artifact.zig"),
        .target = target,
        .optimize = optimize,
    });

    const image_creator_root = b.createModule(.{
        .root_source_file = b.path("Tools/ImageCreator/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const storage_tools = b.createModule(.{
        .root_source_file = sdk_dependency.path("r4os/storage_tools.zig"),
        .target = target,
        .optimize = optimize,
    });
    image_creator_root.addImport("storage_tools", storage_tools);
    const image_creator = b.addExecutable(.{ .name = "imagecreater", .root_module = image_creator_root });

    const ntfs_verify_root = b.createModule(.{
        .root_source_file = b.path("Tools/NtfsVerify/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntfs_verify_root.addImport("storage_tools", storage_tools);
    const ntfs_verify = b.addExecutable(.{ .name = "ntfsverify", .root_module = ntfs_verify_root });

    const r4u_pack_root = b.createModule(.{
        .root_source_file = b.path("Tools/R4UPack/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    r4u_pack_root.addImport("r4u_artifact", r4u_artifact);
    const r4u_pack = b.addExecutable(.{ .name = "r4upack", .root_module = r4u_pack_root });

    const serial_link_host = addTool(b, "seriallink-host", "Tools/SerialLinkHost/src/main.zig", target, optimize);
    const image_plan = addTool(b, "image-plan", "Tools/ImagePlan/src/main.zig", target, optimize);
    const preload_image = addTool(b, "preload-image", "Tools/PreloadImage/src/main.zig", target, optimize);
    const default_registry = addTool(b, "default-registry", "Tools/DefaultRegistry/src/main.zig", target, optimize);

    const tools = [_]*std.Build.Step.Compile{
        image_creator,
        ntfs_verify,
        r4u_pack,
        serial_link_host,
        image_plan,
        preload_image,
        default_registry,
    };
    for (tools) |tool| b.installArtifact(tool);

    const font_tests = addSystemFonts(b, libraries_dependency.namedLazyPath("r4font_format"), optimize);

    const image_plan_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("Tools/ImagePlan/src/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const run_image_plan_tests = b.addRunArtifact(image_plan_tests);

    const r4u_pack_test_root = b.createModule(.{
        .root_source_file = b.path("Tools/R4UPack/src/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const r4u_artifact_test = b.createModule(.{
        .root_source_file = sdk_dependency.path("r4os/r4u_artifact.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    r4u_pack_test_root.addImport("r4u_artifact", r4u_artifact_test);
    const r4u_pack_tests = b.addTest(.{ .root_module = r4u_pack_test_root });
    const run_r4u_pack_tests = b.addRunArtifact(r4u_pack_tests);

    const test_step = b.step("test", "Build all tools and run distribution-owned unit tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_image_plan_tests.step);
    test_step.dependOn(&run_r4u_pack_tests.step);
    test_step.dependOn(font_tests);
}

fn addSystemFonts(
    b: *std.Build,
    r4f_format_path: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    const target = b.graph.host;
    const r4f_format = b.createModule(.{
        .root_source_file = r4f_format_path,
        .target = target,
        .optimize = optimize,
    });
    const r4f_writer = b.createModule(.{
        .root_source_file = b.path("Assets/SystemFonts/r4f_writer.zig"),
        .target = target,
        .optimize = optimize,
    });
    r4f_writer.addImport("r4f_format", r4f_format);

    const terminal8 = addFontGenerator(b, "terminal8-fontgen", "Assets/SystemFonts/Terminal8/src/main.zig", target, optimize);
    terminal8.root_module.addImport("r4f_writer", r4f_writer);
    const terminal8_run = b.addRunArtifact(terminal8);
    installSystemFont(b, terminal8_run.addOutputFileArg(system_font_names[0]), system_font_names[0]);

    const terminal16 = addFontGenerator(b, "terminal16-fontgen", "Assets/SystemFonts/Terminal16/src/main.zig", target, optimize);
    terminal16.root_module.addImport("r4f_writer", r4f_writer);
    const terminal16_run = b.addRunArtifact(terminal16);
    installSystemFont(b, terminal16_run.addOutputFileArg(system_font_names[1]), system_font_names[1]);

    const base_glyphs = b.createModule(.{
        .root_source_file = b.path("Assets/SystemFonts/Terminal8/src/glyphs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const r4sans_root = systemFontModule(b, "Assets/SystemFonts/R4Sans/src/main.zig", target, optimize);
    r4sans_root.addImport("r4f_format", r4f_format);
    r4sans_root.addImport("r4f_writer", r4f_writer);
    r4sans_root.addImport("base_glyphs", base_glyphs);
    const r4sans = b.addExecutable(.{ .name = "r4sans-fontgen", .root_module = r4sans_root });
    const r4sans_run = b.addRunArtifact(r4sans);
    for (system_font_names[2..]) |name| installSystemFont(b, r4sans_run.addOutputFileArg(name), name);

    const test_root = systemFontModule(b, "Assets/SystemFonts/R4Sans/src/main.zig", target, .Debug);
    test_root.addImport("r4f_format", r4f_format);
    test_root.addImport("r4f_writer", r4f_writer);
    test_root.addImport("base_glyphs", base_glyphs);
    const tests = b.addTest(.{ .root_module = test_root });
    return &b.addRunArtifact(tests).step;
}

fn addFontGenerator(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = name, .root_module = systemFontModule(b, source, target, optimize) });
}

fn systemFontModule(
    b: *std.Build,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
    });
}

fn installSystemFont(b: *std.Build, output: std.Build.LazyPath, name: []const u8) void {
    const install = b.addInstallFile(output, b.fmt("share/r4os/fonts/{s}", .{name}));
    b.getInstallStep().dependOn(&install.step);
}

fn addTool(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
        }),
    });
}
