const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const lib = b.addStaticLibrary("zee_alloc", "src/main.zig");
    lib.setBuildMode(mode);

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    const build_docs = b.addSystemCommand([_][]const u8{
        b.zig_exe,
        "test",
        "src/main.zig",
        "-femit-docs",
        "-fno-emit-bin",
        "--output-dir",
        ".",
    });

    const doc_step = b.step("docs", "Generate the docs");
    doc_step.dependOn(&build_docs.step);

    b.default_step.dependOn(&lib.step);
    b.installArtifact(lib);
}
