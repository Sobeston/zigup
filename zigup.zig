const std = @import("std");
const builtin = @import("builtin");
const fixdeletetree = @import("fixdeletetree.zig");

const help =
    \\Download and manage zig compilers.
    \\
    \\Common Usage:
    \\
    \\  zigup VERSION                 download and set VERSION compiler as default
    \\  zigup fetch VERSION           download VERSION compiler
    \\  zigup default [VERSION]       get or set the default compiler
    \\  zigup list                    list installed compiler versions
    \\  zigup clean   [VERSION]       deletes the given compiler version, otherwise, cleans all compilers
    \\                                that aren't the default, master, or marked to keep.
    \\  zigup keep VERSION            mark a compiler to be kept during clean
    \\  zigup run VERSION ARGS...     run the given VERSION of the compiler with the given ARGS...
    \\
    \\Uncommon Usage:
    \\
    \\  zigup fetch-index             download and print the download index json
    \\
    \\Common Options:
    \\  --install-dir DIR             override the default install location
    \\  --path-link PATH              path to the `zig` symlink that points to the default compiler
    \\                                this will typically be a file path within a PATH directory so
    \\                                that the user can just run `zig`
    \\
;

const Command = enum {
    const Argument = struct {
        name: []const u8,
        required: bool = false,
    };

    const enum_len = @typeInfo(Command).Enum.fields.len;
    const enum_strings = blk: {
        var strs: []const []const u8 = &.{};
        for (std.meta.fields(Command)) |enum_field| {
            var str: []const u8 = enum_field.name;
            if (std.mem.eql(u8, str, "fetch_index")) str = "fetch-index";
            strs = strs ++ .{str};
        }
        break :blk strs;
    };

    fn string(self: Command) []const u8 {
        return enum_strings[@intFromEnum(self)];
    }

    none,
    fetch,
    default,
    list,
    clean,
    keep,
    run,
    fetch_index,

    fn getArg(self: Command) ?Argument {
        return switch (self) {
            .none => Argument{ .name = "VERSION", .required = true },
            .fetch => Argument{ .name = "VERSION", .required = true },
            .default => Argument{ .name = "VERSION", .required = false },
            .list => null,
            .clean => Argument{ .name = "VERSION", .required = false },
            .keep => Argument{ .name = "VERSION", .required = true },
            .run => Argument{ .name = "VERSION ARGS...", .required = true },
            .fetch_index => null,
        };
    }

    fn checkRequired(self: Command, argv: []const []const u8) error{AlreadyReported}!void {
        if (self.getArg()) |arg| {
            if (arg.required and argv.len == 0) {
                std.log.err("Missing required arg: {s}", .{arg.name});
                return error.AlreadyReported;
            }
        }
    }

    fn fromArgv(argv: []const []const u8) (error{AlreadyReported} || std.fs.File.WriteError)!Command {
        const command: Command = for (0..enum_len) |i| {
            const str = enum_strings[i];
            if (std.mem.eql(u8, argv[0], str)) {
                break @enumFromInt(i);
            }
        } else cmd: {
            if (argv.len > 1) break :cmd .none;

            try std.io.getStdOut().writeAll(help);
            return error.AlreadyReported;
        };

        try checkRequired(command, argv[1..]);

        return command;
    }
};

const Option = enum {
    install_dir,
    path_link,
    index,

    const enum_len = @typeInfo(Option).Enum.fields.len;

    // TODO: should these all have env var equivalents?
    const enum_strings: [enum_len][]const u8 = .{
        "--install-dir",
        "--path-link",
        "--index",
    };

    fn string(self: Option) []const u8 {
        return enum_strings[@intFromEnum(self)];
    }

    fn getArg(self: Option, argv: []const []const u8) ?[]const u8 {
        for (0.., argv) |i, arg| {
            if (std.mem.eql(u8, arg, self.string())) {
                if (argv.len >= i + 1) return argv[i + 1];
            }
        }
        return null;
    }
};

const defaults = struct {
    const index_url = "https://ziglang.org/download/index.json";

    fn installPath(
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        return switch (builtin.os.tag) {
            else => @panic("unimpl"),
            .linux, .macos => default_path: {
                const home = std.posix.getenv("HOME") orelse {
                    std.log.err("$HOME environment variable is not set.", .{});
                    return error.AlreadyReported;
                };

                if (!std.fs.path.isAbsolute(home)) {
                    std.log.err("$HOME environment variable '{s}' is not an absolute path.", .{home});
                    return error.AlreadyReported;
                }

                break :default_path try std.fs.path.join(allocator, &.{ home, "zig" });
            },
        };
    }
};

pub fn main() !u8 {
    if (builtin.os.tag == .windows) _ = try std.os.windows.WSAStartup(2, 2);

    mainInner() catch |e| switch (e) {
        error.AlreadyReported => return 1,
        else => return e,
    };

    return 0;
}

pub fn mainInner() !void {
    // could use the arena still, but let's check leaks for now
    // var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // const allocator = arena.allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("leaked");
    const allocator = gpa.allocator();

    const args_array = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args_array);
    const argv = if (args_array.len == 0) args_array else args_array[1..];

    if (argv.len == 0) {
        try std.io.getStdOut().writeAll(help);
        return error.AlreadyReported;
    }

    var did_allocate_path: bool = false;
    const install_dir_path: []const u8 = Option.install_dir.getArg(argv) orelse from_env: {
        if (builtin.os.tag == .windows) break :from_env null;
        break :from_env std.posix.getenv("ZIGUP_INSTALL_DIR");
    } orelse allocated: {
        const path = try defaults.installPath(allocator);
        did_allocate_path = true;
        break :allocated path;
    };
    defer if (did_allocate_path) allocator.free(install_dir_path);

    const index_url = Option.index.getArg(argv) orelse defaults.index_url;

    const command = try Command.fromArgv(argv);
    switch (command) {
        .list => {
            const install_dir = try std.fs.openDirAbsolute(install_dir_path, .{ .iterate = true });
            try listCompilers(install_dir);
        },
        .keep => {
            const version = argv[1];
            const install_dir = try std.fs.openDirAbsolute(install_dir_path, .{ .iterate = true });
            try keepCompiler(version, install_dir);
        },
        .run => {
            const version = argv[1];
            const compiler_args = argv[2..];
            const exit_code = try runCompiler(allocator, install_dir_path, version, compiler_args);
            if (exit_code != 0) std.log.info("compiler exited with code: {}.", .{exit_code});
        },
        .fetch_index => {
            const index_string = try downloadIndex(allocator, index_url);
            try std.io.getStdOut().writeAll(index_string);
        },
        .fetch => {
            const version = argv[1];

            const install_dir = try std.fs.openDirAbsolute(install_dir_path, .{ .iterate = true });
            const version_url = try resolveVersionUrl(allocator, version, index_url);
            defer version_url.deinit(allocator);

            errdefer std.log.err("Failed to install version: {s}", .{version_url.version});

            try install_dir.makeDir(version_url.version); // TODO catch existing
            const version_dir = try install_dir.openDir(version_url.version, .{ .iterate = true });

            const is_empty = blk: {
                var iter = version_dir.iterate();
                while (try iter.next()) |_| break :blk false;
                break :blk true;
            };
            if (!is_empty) std.log.err("version {s} already installed.", .{version_url.version});

            try installFromURL(allocator, version_url.url, version_dir);
        },
        .none, .default, .clean => @panic("unimplemented"),
    }
}

fn getDefaultUrl(allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
    const version_kind: enum {
        dev,
        release,
    } = if (std.mem.indexOfAny(u8, version, "-+")) |_| .dev else .release;

    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "armv7a",
        .riscv64 => "riscv64",
        .powerpc64le => "powerpc64le",
        .powerpc => "powerpc",
        else => @compileError("Unsupported CPU Architecture"),
    };
    const os = switch (builtin.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => @compileError("Unsupported OS"),
    };

    const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

    const url_platform = os ++ "-" ++ arch;

    return switch (version_kind) {
        .dev => try std.fmt.allocPrint(
            allocator,
            "https://ziglang.org/builds/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext,
            .{version},
        ),
        .release => try std.fmt.allocPrint(
            allocator,
            "https://ziglang.org/download/{s}/zig-" ++ url_platform ++ "-{0s}." ++ archive_ext,
            .{version},
        ),
    };
}

fn installFromURL(
    allocator: std.mem.Allocator,
    archive_url: []const u8,
    version_dir: std.fs.Dir,
) !void {
    errdefer std.log.err("Failed to install {s}.", .{archive_url});

    try version_dir.makeDir(".installing");
    var installing_dir = try version_dir.openDir(".installing", .{});
    defer {
        installing_dir.close();
        version_dir.deleteDir(".installing") catch |err| {
            std.log.err("failed to delete .installing folder, error: {s}", .{@errorName(err)});
        };
    }

    const archive_name = std.fs.path.basename(archive_url);

    var archive_file = try installing_dir.createFile(
        archive_name,
        .{ .exclusive = true, .read = true },
    );
    defer {
        archive_file.close();
        installing_dir.deleteFile(archive_name) catch |err| {
            std.log.err("failed to delete archive {s}, error: {s}", .{
                archive_name,
                @errorName(err),
            });
        };
    }

    try download(allocator, archive_url, archive_file.writer());
    try archive_file.seekTo(0);

    const archive_kind: enum { tarxz, zip } = if (std.mem.endsWith(u8, archive_name, ".tar.xz"))
        .tarxz
    else if (std.mem.endsWith(u8, archive_name, ".zip"))
        .zip
    else {
        std.log.err("Invalid file extension for archive: {s}, expected .tar.xz or .zip", .{archive_name});
        return error.AlreadyReported;
    };

    switch (archive_kind) {
        .tarxz => {
            errdefer std.log.err("Failed to extract .tar.xz", .{});
            std.log.info("Extracting .tar.xz", .{});

            var buffered = std.io.bufferedReader(archive_file.reader());

            var decompressor = try std.compress.xz.decompress(
                allocator,
                buffered.reader(),
            );
            defer decompressor.deinit();

            try std.tar.pipeToFileSystem(version_dir, decompressor.reader(), .{});
            const folder_name = archive_name[0 .. archive_name.len - ".tar.xz".len];
            try std.fs.Dir.rename(version_dir, folder_name, "files");
        },
        .zip => @panic("todo"),
    }
}

fn download(allocator: std.mem.Allocator, url: []const u8, writer: anytype) !void {
    errdefer std.log.err("Failed to download {s}.", .{url});
    std.log.info("Downloading url {s}", .{url});

    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    try client.initDefaultProxies(allocator);

    var server_header_buffer: [std.mem.page_size]u8 = undefined;
    var request = try client.open(.GET, uri, .{
        .keep_alive = false,
        .server_header_buffer = &server_header_buffer,
    });
    defer request.deinit();

    try request.send();
    try request.wait();

    if (request.response.status != .ok) {
        std.log.err("Bad response: {}.", .{request.response.status});
        return error.AlreadyReported;
    }

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = std.mem.page_size }).init();
    try fifo.pump(request.reader(), writer);
}

const ResolvedVersionAndURL = struct {
    version: []const u8,
    url: []const u8,
    fn deinit(self: ResolvedVersionAndURL, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.url);
    }
};

fn resolveVersionUrl(
    allocator: std.mem.Allocator,
    version: []const u8,
    index_url: []const u8,
) !ResolvedVersionAndURL {
    errdefer std.log.err("Failed to resolve version {s}.", .{version});

    const is_master = std.mem.eql(u8, version, "master");
    const is_default_index = std.mem.eql(u8, index_url, defaults.index_url);

    // no index lookup required
    if (!is_master and is_default_index) {
        return ResolvedVersionAndURL{
            .version = try allocator.dupe(u8, version),
            .url = try getDefaultUrl(allocator, version),
        };
    }

    const index_string = try downloadIndex(allocator, index_url);
    defer allocator.free(index_string);

    // TODO: this isn't right
    const IndexMaster = struct {
        const Entry = struct {
            version: []const u8,
            @"x86_64-linux": struct { // no
                tarball: []const u8,
            },
        };

        master: Entry, // no
    };

    const parsed = try std.json.parseFromSlice(
        IndexMaster,
        allocator,
        index_string,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    return ResolvedVersionAndURL{
        .version = try allocator.dupe(u8, parsed.value.master.version),
        .url = try allocator.dupe(u8, parsed.value.master.@"x86_64-linux".tarball),
    };
}

fn downloadIndex(
    allocator: std.mem.Allocator,
    index_url: []const u8,
) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    try client.initDefaultProxies(allocator);

    // init with 100KiB - as of writing, the index.json is ~47KiB
    var response_body = try std.ArrayList(u8).initCapacity(allocator, 1024 * 100);

    const result = try client.fetch(.{
        .location = .{ .url = index_url },
        .method = .GET,
        .response_storage = .{ .dynamic = &response_body },
    });

    if (result.status != .ok) {
        std.log.err(
            "Bad response ({}) while fetching index ({s})",
            .{ result.status, index_url },
        );
        return error.AlreadyReported;
    }

    return try response_body.toOwnedSlice();
}

pub fn runCompiler(
    allocator: std.mem.Allocator,
    install_dir_path: []const u8,
    version: []const u8,
    compiler_args: []const []const u8,
) !u8 {
    const compiler_dir = try std.fs.path.join(allocator, &.{ install_dir_path, version });
    defer allocator.free(compiler_dir);

    if (!try existsAbsolute(compiler_dir)) {
        std.log.err("compiler '{s}' does not exist, fetch it first with: zigup fetch {0s}", .{version});
        return error.AlreadyReported;
    }

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    const compiler_path = try std.fs.path.join(allocator, &.{
        compiler_dir,
        "files",
        comptime "zig" ++ builtin.target.exeFileExt(),
    });
    defer allocator.free(compiler_path);

    try argv.append(compiler_path);
    try argv.appendSlice(compiler_args);

    // TODO: use "execve" if on linux
    var proc = std.process.Child.init(argv.items, allocator);
    const ret_val = try proc.spawnAndWait();
    switch (ret_val) {
        .Exited => |code| return code,
        else => |result| {
            std.log.err("compiler exited unexpectedly with {}", .{result});
            return error.AlreadyReported;
        },
    }
}

// TODO: this should be in std lib somewhere
fn existsAbsolute(absolutePath: []const u8) !bool {
    std.fs.cwd().access(absolutePath, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        error.PermissionDenied => return e,
        error.InputOutput => return e,
        error.SystemResources => return e,
        error.SymLinkLoop => return e,
        error.FileBusy => return e,
        error.Unexpected => unreachable,
        error.InvalidUtf8 => return e,
        error.InvalidWtf8 => return e,
        error.ReadOnlyFileSystem => unreachable,
        error.NameTooLong => unreachable,
        error.BadPathName => unreachable,
    };
    return true;
}

fn listCompilers(install_dir: std.fs.Dir) !void {
    const stdout = std.io.getStdOut().writer();
    {
        var it = install_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory)
                continue;
            if (std.mem.endsWith(u8, entry.name, ".installing"))
                continue;
            try stdout.print("{s}\n", .{entry.name});
        }
    }
}

fn keepCompiler(version: []const u8, install_dir: std.fs.Dir) !void {
    var compiler_dir = install_dir.openDir(version, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.err("compiler not found: {s}", .{version});
            return error.AlreadyReported;
        },
        else => return e,
    };
    var keep_fd = try compiler_dir.createFile("keep", .{});
    keep_fd.close();
}
