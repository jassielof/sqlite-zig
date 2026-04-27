const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod_name = "sqlite";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const sqlite_c_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const sqlite_c_lib = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = sqlite_c_mod,
    });
    sqlite_c_mod.addIncludePath(sqlite_dep.path("."));
    sqlite_c_mod.addIncludePath(b.path("src/lib/c"));
    sqlite_c_mod.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{"-std=c99"},
    });
    sqlite_c_mod.addCSourceFile(.{
        .file = b.path("src/lib/c/workaround.c"),
        .flags = &.{"-std=c99"},
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/lib/c/workaround.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(sqlite_dep.path("."));
    translate_c.addIncludePath(b.path("src/lib/c"));

    const lib_mod = b.addModule(mod_name, .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{
                .name = "c",
                .module = translate_c.createModule(),
            },
        },
    });
    lib_mod.addIncludePath(sqlite_dep.path("."));
    lib_mod.addIncludePath(b.path("src/lib/c"));
    lib_mod.linkLibrary(sqlite_c_lib);

    const docs_step = b.step("docs", "Generate the documentation");

    const docs_lib = b.addLibrary(.{
        .name = mod_name,
        .root_module = lib_mod,
    });

    const docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    docs_step.dependOn(&docs.step);

    const tests_step = b.step("tests", "Run the test suite");

    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/suite.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{
                    .name = mod_name,
                    .module = lib_mod,
                },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    tests_step.dependOn(&run_integration_tests.step);

    const unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    tests_step.dependOn(&run_unit_tests.step);
}
