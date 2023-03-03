id: Id,
name: []const u8,
owner: *Build,
makeFn: MakeFn,
dependencies: std.ArrayList(*Step),
/// This field is empty during execution of the user's build script, and
/// then populated during dependency loop checking in the build runner.
dependants: std.ArrayListUnmanaged(*Step),
state: State,
/// The return addresss associated with creation of this step that can be useful
/// to print along with debugging messages.
debug_stack_trace: [n_debug_stack_frames]usize,

result_error_msgs: std.ArrayListUnmanaged([]const u8),
result_error_bundle: std.zig.ErrorBundle,
result_cached: bool,
result_duration_ns: ?u64,
/// 0 means unavailable or not reported.
result_peak_rss: usize,

pub const MakeFn = *const fn (self: *Step, prog_node: *std.Progress.Node) anyerror!void;

const n_debug_stack_frames = 4;

pub const State = enum {
    precheck_unstarted,
    precheck_started,
    precheck_done,
    running,
    dependency_failure,
    success,
    failure,
    /// This state indicates that the step did not complete, however, it also did not fail,
    /// and it is safe to continue executing its dependencies.
    skipped,
};

pub const Id = enum {
    top_level,
    compile,
    install_artifact,
    install_file,
    install_dir,
    log,
    remove_dir,
    fmt,
    translate_c,
    write_file,
    run,
    check_file,
    check_object,
    config_header,
    objcopy,
    options,
    custom,

    pub fn Type(comptime id: Id) type {
        return switch (id) {
            .top_level => Build.TopLevelStep,
            .compile => Build.CompileStep,
            .install_artifact => Build.InstallArtifactStep,
            .install_file => Build.InstallFileStep,
            .install_dir => Build.InstallDirStep,
            .log => Build.LogStep,
            .remove_dir => Build.RemoveDirStep,
            .fmt => Build.FmtStep,
            .translate_c => Build.TranslateCStep,
            .write_file => Build.WriteFileStep,
            .run => Build.RunStep,
            .check_file => Build.CheckFileStep,
            .check_object => Build.CheckObjectStep,
            .config_header => Build.ConfigHeaderStep,
            .objcopy => Build.ObjCopyStep,
            .options => Build.OptionsStep,
            .custom => @compileError("no type available for custom step"),
        };
    }
};

pub const Options = struct {
    id: Id,
    name: []const u8,
    owner: *Build,
    makeFn: MakeFn = makeNoOp,
    first_ret_addr: ?usize = null,
};

pub fn init(options: Options) Step {
    const arena = options.owner.allocator;

    var addresses = [1]usize{0} ** n_debug_stack_frames;
    const first_ret_addr = options.first_ret_addr orelse @returnAddress();
    var stack_trace = std.builtin.StackTrace{
        .instruction_addresses = &addresses,
        .index = 0,
    };
    std.debug.captureStackTrace(first_ret_addr, &stack_trace);

    return .{
        .id = options.id,
        .name = arena.dupe(u8, options.name) catch @panic("OOM"),
        .owner = options.owner,
        .makeFn = options.makeFn,
        .dependencies = std.ArrayList(*Step).init(arena),
        .dependants = .{},
        .state = .precheck_unstarted,
        .debug_stack_trace = addresses,
        .result_error_msgs = .{},
        .result_error_bundle = std.zig.ErrorBundle.empty,
        .result_cached = false,
        .result_duration_ns = null,
        .result_peak_rss = 0,
    };
}

/// If the Step's `make` function reports `error.MakeFailed`, it indicates they
/// have already reported the error. Otherwise, we add a simple error report
/// here.
pub fn make(s: *Step, prog_node: *std.Progress.Node) error{ MakeFailed, MakeSkipped }!void {
    return s.makeFn(s, prog_node) catch |err| switch (err) {
        error.MakeFailed => return error.MakeFailed,
        error.MakeSkipped => return error.MakeSkipped,
        else => {
            const gpa = s.dependencies.allocator;
            s.result_error_msgs.append(gpa, @errorName(err)) catch @panic("OOM");
            return error.MakeFailed;
        },
    };
}

pub fn dependOn(self: *Step, other: *Step) void {
    self.dependencies.append(other) catch @panic("OOM");
}

pub fn getStackTrace(s: *Step) std.builtin.StackTrace {
    const stack_addresses = &s.debug_stack_trace;
    var len: usize = 0;
    while (len < n_debug_stack_frames and stack_addresses[len] != 0) {
        len += 1;
    }
    return .{
        .instruction_addresses = stack_addresses,
        .index = len,
    };
}

fn makeNoOp(self: *Step, prog_node: *std.Progress.Node) anyerror!void {
    _ = self;
    _ = prog_node;
}

pub fn cast(step: *Step, comptime T: type) ?*T {
    if (step.id == T.base_id) {
        return @fieldParentPtr(T, "step", step);
    }
    return null;
}

/// For debugging purposes, prints identifying information about this Step.
pub fn dump(step: *Step) void {
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();

    const stderr = std.io.getStdErr();
    const w = stderr.writer();
    const tty_config = std.debug.detectTTYConfig(stderr);
    const debug_info = std.debug.getSelfDebugInfo() catch |err| {
        w.print("Unable to dump stack trace: Unable to open debug info: {s}\n", .{
            @errorName(err),
        }) catch {};
        return;
    };
    const ally = debug_info.allocator;
    w.print("name: '{s}'. creation stack trace:\n", .{step.name}) catch {};
    std.debug.writeStackTrace(step.getStackTrace(), w, ally, debug_info, tty_config) catch |err| {
        stderr.writer().print("Unable to dump stack trace: {s}\n", .{@errorName(err)}) catch {};
        return;
    };
}

const Step = @This();
const std = @import("../std.zig");
const Build = std.Build;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const builtin = @import("builtin");

pub fn evalChildProcess(s: *Step, argv: []const []const u8) !void {
    const arena = s.owner.allocator;

    try handleChildProcUnsupported(s, null, argv);
    try handleVerbose(s.owner, null, argv);

    const result = std.ChildProcess.exec(.{
        .allocator = arena,
        .argv = argv,
    }) catch |err| return s.fail("unable to spawn {s}: {s}", .{ argv[0], @errorName(err) });

    if (result.stderr.len > 0) {
        try s.result_error_msgs.append(arena, result.stderr);
    }

    try handleChildProcessTerm(s, result.term, null, argv);
}

pub fn fail(step: *Step, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, MakeFailed } {
    try step.addError(fmt, args);
    return error.MakeFailed;
}

pub fn addError(step: *Step, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
    const arena = step.owner.allocator;
    const msg = try std.fmt.allocPrint(arena, fmt, args);
    try step.result_error_msgs.append(arena, msg);
}

/// Assumes that argv contains `--listen=-` and that the process being spawned
/// is the zig compiler - the same version that compiled the build runner.
pub fn evalZigProcess(
    s: *Step,
    argv: []const []const u8,
    prog_node: *std.Progress.Node,
) ![]const u8 {
    assert(argv.len != 0);
    const b = s.owner;
    const arena = b.allocator;
    const gpa = arena;

    try handleChildProcUnsupported(s, null, argv);
    try handleVerbose(s.owner, null, argv);

    var child = std.ChildProcess.init(argv, arena);
    child.env_map = b.env_map;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.request_resource_usage_statistics = true;

    child.spawn() catch |err| return s.fail("unable to spawn {s}: {s}", .{
        argv[0], @errorName(err),
    });
    var timer = try std.time.Timer.start();

    var poller = std.io.poll(gpa, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    try sendMessage(child.stdin.?, .update);
    try sendMessage(child.stdin.?, .exit);

    const Header = std.zig.Server.Message.Header;
    var result: ?[]const u8 = null;

    var node_name: std.ArrayListUnmanaged(u8) = .{};
    defer node_name.deinit(gpa);
    var sub_prog_node: ?std.Progress.Node = null;
    defer if (sub_prog_node) |*n| n.end();

    const stdout = poller.fifo(.stdout);

    poll: while (try poller.poll()) {
        while (true) {
            const buf = stdout.readableSlice(0);
            assert(stdout.readableLength() == buf.len);
            if (buf.len < @sizeOf(Header)) continue :poll;
            const header = @ptrCast(*align(1) const Header, buf[0..@sizeOf(Header)]);
            const header_and_msg_len = header.bytes_len + @sizeOf(Header);
            if (buf.len < header_and_msg_len) continue :poll;
            const body = buf[@sizeOf(Header)..][0..header.bytes_len];
            switch (header.tag) {
                .zig_version => {
                    if (!std.mem.eql(u8, builtin.zig_version_string, body)) {
                        return s.fail(
                            "zig version mismatch build runner vs compiler: '{s}' vs '{s}'",
                            .{ builtin.zig_version_string, body },
                        );
                    }
                },
                .error_bundle => {
                    const EbHdr = std.zig.Server.Message.ErrorBundle;
                    const eb_hdr = @ptrCast(*align(1) const EbHdr, body);
                    const extra_bytes =
                        body[@sizeOf(EbHdr)..][0 .. @sizeOf(u32) * eb_hdr.extra_len];
                    const string_bytes =
                        body[@sizeOf(EbHdr) + extra_bytes.len ..][0..eb_hdr.string_bytes_len];
                    // TODO: use @ptrCast when the compiler supports it
                    const unaligned_extra = std.mem.bytesAsSlice(u32, extra_bytes);
                    const extra_array = try arena.alloc(u32, unaligned_extra.len);
                    // TODO: use @memcpy when it supports slices
                    for (extra_array, unaligned_extra) |*dst, src| dst.* = src;
                    s.result_error_bundle = .{
                        .string_bytes = try arena.dupe(u8, string_bytes),
                        .extra = extra_array,
                    };
                },
                .progress => {
                    if (sub_prog_node) |*n| n.end();
                    node_name.clearRetainingCapacity();
                    try node_name.appendSlice(gpa, body);
                    sub_prog_node = prog_node.start(node_name.items, 0);
                    sub_prog_node.?.activate();
                },
                .emit_bin_path => {
                    const EbpHdr = std.zig.Server.Message.EmitBinPath;
                    const ebp_hdr = @ptrCast(*align(1) const EbpHdr, body);
                    s.result_cached = ebp_hdr.flags.cache_hit;
                    result = try arena.dupe(u8, body[@sizeOf(EbpHdr)..]);
                },
                _ => {
                    // Unrecognized message.
                },
            }
            stdout.discard(header_and_msg_len);
        }
    }

    const stderr = poller.fifo(.stderr);
    if (stderr.readableLength() > 0) {
        try s.result_error_msgs.append(arena, try stderr.toOwnedSlice());
    }

    // Send EOF to stdin.
    child.stdin.?.close();
    child.stdin = null;

    const term = child.wait() catch |err| {
        return s.fail("unable to wait for {s}: {s}", .{ argv[0], @errorName(err) });
    };
    s.result_duration_ns = timer.read();
    s.result_peak_rss = child.resource_usage_statistics.getMaxRss() orelse 0;

    try handleChildProcessTerm(s, term, null, argv);

    if (s.result_error_bundle.errorMessageCount() > 0) {
        return s.fail("the following command failed with {d} compilation errors:\n{s}", .{
            s.result_error_bundle.errorMessageCount(),
            try allocPrintCmd(arena, null, argv),
        });
    }

    return result orelse return s.fail(
        "the following command failed to communicate the compilation result:\n{s}",
        .{try allocPrintCmd(arena, null, argv)},
    );
}

fn sendMessage(file: std.fs.File, tag: std.zig.Client.Message.Tag) !void {
    const header: std.zig.Client.Message.Header = .{
        .tag = tag,
        .bytes_len = 0,
    };
    try file.writeAll(std.mem.asBytes(&header));
}

pub fn handleVerbose(
    b: *Build,
    opt_cwd: ?[]const u8,
    argv: []const []const u8,
) error{OutOfMemory}!void {
    if (b.verbose) {
        // Intention of verbose is to print all sub-process command lines to
        // stderr before spawning them.
        const text = try allocPrintCmd(b.allocator, opt_cwd, argv);
        std.debug.print("{s}\n", .{text});
    }
}

pub inline fn handleChildProcUnsupported(
    s: *Step,
    opt_cwd: ?[]const u8,
    argv: []const []const u8,
) error{ OutOfMemory, MakeFailed }!void {
    if (!std.process.can_spawn) {
        return s.fail(
            "unable to execute the following command: host cannot spawn child processes\n{s}",
            .{try allocPrintCmd(s.owner.allocator, opt_cwd, argv)},
        );
    }
}

pub fn handleChildProcessTerm(
    s: *Step,
    term: std.ChildProcess.Term,
    opt_cwd: ?[]const u8,
    argv: []const []const u8,
) error{ MakeFailed, OutOfMemory }!void {
    const arena = s.owner.allocator;
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                return s.fail(
                    "the following command exited with error code {d}:\n{s}",
                    .{ code, try allocPrintCmd(arena, opt_cwd, argv) },
                );
            }
        },
        .Signal, .Stopped, .Unknown => {
            return s.fail(
                "the following command terminated unexpectedly:\n{s}",
                .{try allocPrintCmd(arena, opt_cwd, argv)},
            );
        },
    }
}

pub fn allocPrintCmd(arena: Allocator, opt_cwd: ?[]const u8, argv: []const []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .{};
    if (opt_cwd) |cwd| try buf.writer(arena).print("cd {s} && ", .{cwd});
    for (argv) |arg| {
        try buf.writer(arena).print("{s} ", .{arg});
    }
    return buf.toOwnedSlice(arena);
}

pub fn cacheHit(s: *Step, man: *std.Build.Cache.Manifest) !bool {
    return man.hit() catch |err| return failWithCacheError(s, man, err);
}

fn failWithCacheError(s: *Step, man: *const std.Build.Cache.Manifest, err: anyerror) anyerror {
    const i = man.failed_file_index orelse return err;
    const pp = man.files.items[i].prefixed_path orelse return err;
    const prefix = man.cache.prefixes()[pp.prefix].path orelse "";
    return s.fail("{s}: {s}/{s}", .{ @errorName(err), prefix, pp.sub_path });
}
