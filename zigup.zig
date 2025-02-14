const std = @import("std");
const builtin = @import("builtin");

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
    \\  --index URL                   override the default index URL
    \\  --path-link PATH              path to the `zig` symlink that points to the default compiler
    \\                                this will typically be a file path within a PATH directory so
    \\                                that the user can just run `zig`
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
            if (argv.len == 1) break :cmd .none;

            try std.io.getStdOut().writeAll(help);
            return error.AlreadyReported;
        };

        try checkRequired(
            command,
            if (command == .none) argv else argv[1..],
        );

        return command;
    }
};

const Option = enum {
    install_dir,
    path_link,
    index,

    const enum_len = @typeInfo(Option).Enum.fields.len;

    const argv_strings: [enum_len][]const u8 = .{
        "--install-dir",
        "--path-link",
        "--index",
    };

    const env_var_strings: [enum_len][]const u8 = .{
        "ZIGUP_INSTALL_DIR",
        "ZIGUP_PATH_LINK",
        "ZIGUP_INDEX",
    };

    const static_defaults: [enum_len]?[]const u8 = .{ null, null, defaults.index_url };

    fn argvString(self: Option) []const u8 {
        return argv_strings[@intFromEnum(self)];
    }

    fn envVarString(self: Option) []const u8 {
        return env_var_strings[@intFromEnum(self)];
    }

    fn defaultStatic(self: Option) ?[]const u8 {
        return static_defaults[@intFromEnum(self)];
    }

    const FoundValue = struct {
        const From = enum { argv, env_var, default_static, default_dynamic };
        value: []const u8,
        from: From,
        fn deinit(self: FoundValue, allocator: std.mem.Allocator) void {
            if (self.from == .env_var or self.from == .default_dynamic) allocator.free(self.value);
        }
    };

    const FallBackError = error{ OutOfMemory, AlreadyReported };

    fn getArg(
        self: Option,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        context: anytype,
        fallback_fn: ?*const fn (std.mem.Allocator, @TypeOf(context)) FallBackError![]const u8,
    ) !FoundValue {
        if (self.defaultStatic() == null and fallback_fn == null)
            unreachable;

        for (0.., argv) |i, arg| {
            if (std.mem.eql(u8, arg, self.argvString())) {
                if (argv.len >= i + 1) {
                    return FoundValue{ .value = argv[i + 1], .from = .argv };
                }
            }
        }

        if (std.process.getEnvVarOwned(allocator, self.envVarString()) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        }) |v| {
            return FoundValue{ .value = v, .from = .env_var };
        }

        if (self.defaultStatic()) |v| {
            return FoundValue{ .value = v, .from = .default_static };
        }

        if (fallback_fn) |fallback| {
            return FoundValue{
                .value = try fallback(allocator, context),
                .from = .default_dynamic,
            };
        }

        unreachable;
    }
};

const defaults = struct {
    const index_url = "https://ziglang.org/download/index.json";

    fn installPath(
        allocator: std.mem.Allocator,
        context: void,
    ) Option.FallBackError![]const u8 {
        _ = context;

        return switch (builtin.os.tag) {
            else => @panic("unimplemented"),
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

    fn zigPathLink(
        allocator: std.mem.Allocator,
        install_path: []const u8,
    ) Option.FallBackError![]const u8 {
        return try std.fs.path.join(
            allocator,
            &.{ install_path, "zig" ++ comptime builtin.target.exeFileExt() },
        );
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

    const install_dir_path = try Option.install_dir.getArg(
        allocator,
        argv,
        {},
        defaults.installPath,
    );
    defer install_dir_path.deinit(allocator);

    const path_link = try Option.path_link.getArg(
        allocator,
        argv,
        install_dir_path.value,
        defaults.zigPathLink,
    );
    defer path_link.deinit(allocator);

    const index_url = try Option.index.getArg(allocator, argv, {}, null);
    defer index_url.deinit(allocator);

    const command = try Command.fromArgv(argv);
    switch (command) {
        .list => {
            var install_dir = try std.fs.openDirAbsolute(install_dir_path.value, .{ .iterate = true });
            defer install_dir.close();

            try listCompilers(install_dir);
        },
        .keep => {
            const version = argv[1];

            var install_dir = try std.fs.openDirAbsolute(install_dir_path.value, .{ .iterate = true });
            defer install_dir.close();

            try keepCompiler(version, install_dir);
        },
        .run => {
            const version = argv[1];
            const compiler_args = argv[2..];

            const exit_code = try runCompiler(allocator, install_dir_path.value, version, compiler_args);
            if (exit_code != 0) std.log.info("compiler exited with code: {}.", .{exit_code});
        },
        .fetch_index => {
            const index_string = try downloadIndex(allocator, index_url.value);
            try std.io.getStdOut().writeAll(index_string);
        },
        .fetch => {
            const version = argv[1];

            var install_dir = try std.fs.openDirAbsolute(install_dir_path.value, .{ .iterate = true });
            defer install_dir.close();

            const resolved_version = try installVersion(allocator, install_dir, version, index_url.value);
            defer allocator.free(resolved_version.string);
        },
        .default => {
            var install_dir = try std.fs.openDirAbsolute(install_dir_path.value, .{ .iterate = true });
            defer install_dir.close();

            if (argv.len == 1) {
                errdefer std.log.err("Failed to get as default compiler path.", .{});

                std.log.info("zig symlink at: {s}", .{path_link.value});

                const default_compiler_path = try getDefaultCompilerPath(allocator, path_link.value);
                defer if (default_compiler_path) |path| allocator.free(path);

                try std.io.getStdOut().writer().print(
                    "zig default compiler at: {s}\n",
                    .{default_compiler_path orelse "<nothing?>"},
                );
            } else {
                const version = argv[1];

                try setDefault(allocator, install_dir, path_link.value, version);
            }
        },
        .none => {
            const version = argv[0];

            var install_dir = try std.fs.openDirAbsolute(install_dir_path.value, .{ .iterate = true });
            defer install_dir.close();

            var dir = install_dir.openDir(version, .{}) catch |err| switch (err) {
                else => return err,
                error.FileNotFound => {
                    std.log.info("version {s} not found, fetching", .{version});

                    const resolved_version = try installVersion(
                        allocator,
                        install_dir,
                        version,
                        index_url.value,
                    );
                    defer allocator.free(resolved_version.string);
                    try setDefault(allocator, install_dir, path_link.value, resolved_version.string);

                    return; // TODO - not great?
                },
            };
            dir.close();

            std.log.info("version {s} already exists, setting as default", .{version});

            try setDefault(allocator, install_dir, path_link.value, version);
        },
        .clean => {
            const clean_mode = if (argv.len == 2)
                CleanMode{ .version = argv[1] }
            else
                CleanMode.all;

            var install_dir = try std.fs.openDirAbsolute(install_dir_path.value, .{ .iterate = true });
            defer install_dir.close();

            try cleanCompilers(allocator, install_dir, clean_mode, path_link.value);
        },
    }
}

const ResolvedVersion = struct {
    string: []const u8,
};

fn installVersion(allocator: std.mem.Allocator, install_dir: std.fs.Dir, version: []const u8, index_url: []const u8) !ResolvedVersion {
    const version_url = try resolveVersionUrl(allocator, version, index_url);
    defer allocator.free(version_url.url);
    errdefer allocator.free(version_url.version);

    errdefer std.log.err("Failed to install version: {s}", .{version_url.version});

    const version_dir = makeNewVersionDir(install_dir, version_url.version) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.log.info("found version: {s}, which is already installed", .{version_url.version});
            return ResolvedVersion{ .string = version_url.version };
        },
        else => return err,
    };

    errdefer install_dir.deleteDir(version_url.version) catch {
        std.log.err("failed to delete version folder: {s}", .{version_url.version});
    };

    try installFromURL(allocator, version_url.url, version_dir);

    return ResolvedVersion{ .string = version_url.version };
}

/// fails if version does not exist
fn setDefault(
    allocator: std.mem.Allocator,
    install_dir: std.fs.Dir,
    path_link: []const u8,
    version: []const u8,
) !void {
    errdefer std.log.err("Failed to set {s} as default.", .{version});

    const default_compiler_path = try getDefaultCompilerPath(allocator, path_link);
    defer if (default_compiler_path) |path| allocator.free(path);

    if (default_compiler_path) |path| {
        if (std.mem.endsWith(u8, path, version)) {
            std.log.err("Version already default: {s}", .{version});
            return error.AlreadyReported;
        }
    }

    errdefer std.log.err("Error replacing symlink", .{});

    var version_dir = try install_dir.openDir(version, .{});
    defer version_dir.close();

    var files_dir = try version_dir.openDir("files", .{});
    defer files_dir.close();

    std.log.info("replacing symlink", .{});

    const versioned_binary_path = try std.fs.path.join(allocator, &.{
        version,
        "files",
        "zig" ++ comptime builtin.target.exeFileExt(),
    });
    defer allocator.free(versioned_binary_path);

    try install_dir.deleteFile("zig");

    switch (builtin.os.tag) {
        else => {
            try std.posix.symlinkat(
                versioned_binary_path,
                install_dir.fd,
                "zig",
            );
        },
        .windows => {
            @panic("unimplemented");
        },
    }
}

const CleanMode = union(enum) { all, version: []const u8 };

fn cleanCompilers(
    allocator: std.mem.Allocator,
    install_dir: std.fs.Dir,
    mode: CleanMode,
    path_link: []const u8,
) !void {
    const default_compiler_path = try getDefaultCompilerPath(allocator, path_link);
    defer if (default_compiler_path) |path| allocator.free(path);

    _ = install_dir;
    _ = mode;

    @panic("unimplemented");
}

fn shouldSkipClean(version: []const u8) bool {
    _ = version;
    return false; // TODO
}

fn getDefaultCompilerPath(
    allocator: std.mem.Allocator,
    path_link: []const u8,
) !?[]const u8 {
    var buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const target_path: []u8 = std.fs.readLinkAbsolute(path_link, &buffer) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    return try allocator.dupe(u8, target_path);
}

fn makeNewVersionDir(install_dir: std.fs.Dir, version: []const u8) !std.fs.Dir {
    try install_dir.makeDir(version);
    const version_dir = try install_dir.openDir(version, .{ .iterate = true });
    errdefer install_dir.deleteDir(version) catch {
        std.log.err("failed to delete version folder: {s}", .{version});
    };

    const is_empty = blk: {
        var iter = version_dir.iterate();
        while (try iter.next()) |_| break :blk false;
        break :blk true;
    };
    if (!is_empty) {
        std.log.err("version {s} already installed.", .{version});
        return error.AlreadyReported;
    }

    return version_dir;
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
        .zip => {
            var stream = archive_file.seekableStream();

            // TODO this is probably slow?
            try std.zip.extract(version_dir, &stream, .{});
            const folder_name = archive_name[0 .. archive_name.len - ".zip".len];
            try std.fs.Dir.rename(version_dir, folder_name, "files");
        },
    }

    // TODO: update master symlink
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

        error.PermissionDenied,
        error.InputOutput,
        error.SystemResources,
        error.SymLinkLoop,
        error.FileBusy,
        error.InvalidUtf8,
        error.InvalidWtf8,
        => return e,

        error.ReadOnlyFileSystem,
        error.NameTooLong,
        error.BadPathName,
        error.Unexpected,
        => unreachable,
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
