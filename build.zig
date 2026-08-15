const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk_dependency = b.dependency("r4os_sdk", .{
        .target = target,
        .optimize = optimize,
    });
    const ntfs_format = b.createModule(.{
        .root_source_file = sdk_dependency.path("r4os/ntfs_format.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    image_creator_root.addImport("ntfs_format", ntfs_format);
    const image_creator = b.addExecutable(.{ .name = "imagecreater", .root_module = image_creator_root });

    const ntfs_verify_root = b.createModule(.{
        .root_source_file = b.path("Tools/NtfsVerify/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntfs_verify_root.addImport("ntfs_format", ntfs_format);
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
