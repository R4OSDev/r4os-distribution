const std = @import("std");

const net = std.Io.net;

const MAGIC = [_]u8{ 'R', '4', 'S', 'L' };
const VERSION: u8 = 1;
const TYPE_DIAG: u8 = 1;
const TYPE_MESSAGE: u8 = 2;
const HEADER_SIZE: usize = 10;
const MAX_PAYLOAD: usize = 256;
const MAX_FRAME: usize = HEADER_SIZE + MAX_PAYLOAD;

const Frame = struct {
    frame_type: u8,
    payload: []const u8,
};

const Options = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 44126,
    attempts: u32 = 200,
    sleep_ms: i64 = 50,
    inject_errors: bool = false,
    message: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parseArgs(args);
    const io = init.io;

    var stream = try connectWithRetry(io, options);
    defer stream.close(io);

    var reader_buffer: [512]u8 = undefined;
    var writer_buffer: [512]u8 = undefined;
    var reader_state = net.Stream.reader(stream, io, &reader_buffer);
    var writer_state = net.Stream.writer(stream, io, &writer_buffer);
    const reader = &reader_state.interface;
    const writer = &writer_state.interface;

    var ready_payload: [MAX_PAYLOAD]u8 = undefined;
    var skipped: u32 = 0;
    while (true) {
        const ready = try readFrame(reader, &ready_payload);
        if (payloadEquals(ready, TYPE_DIAG, "R4OS-HOST-READY")) break;
        skipped += 1;
        std.debug.print("seriallink-host: skipped frame type={d} payload_len={d}\n", .{ ready.frame_type, ready.payload.len });
    }
    std.debug.print("seriallink-host: ready received\n", .{});

    if (options.inject_errors) {
        try injectErrors(writer);
        std.debug.print("seriallink-host: injected bad-magic/bad-length/bad-checksum\n", .{});
    }

    if (options.message) |message| {
        try writeFrame(writer, TYPE_MESSAGE, message);
        std.debug.print("seriallink-host: message sent len={d}\n", .{message.len});
    }

    try writeFrame(writer, TYPE_DIAG, "HOST-R4SL-HELLO");
    std.debug.print("seriallink-host: hello sent\n", .{});

    var ack_payload: [MAX_PAYLOAD]u8 = undefined;
    const ack = try readFrame(reader, &ack_payload);
    try expectPayload(ack, TYPE_DIAG, "R4OS-HOST-ACK");
    std.debug.print("seriallink-host: ack received\n", .{});
    std.debug.print("seriallink-host: ok host={s} port={d} skipped={d}\n", .{ options.host, options.port, skipped });
}

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--host")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            options.host = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            options.port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--attempts")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            options.attempts = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--sleep-ms")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            options.sleep_ms = try std.fmt.parseInt(i64, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--inject-errors")) {
            options.inject_errors = true;
        } else if (std.mem.eql(u8, arg, "--message")) {
            if (i + 1 >= args.len) return error.BadArgs;
            i += 1;
            options.message = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return error.HelpRequested;
        } else {
            std.debug.print("Unbekanntes Argument: {s}\n", .{arg});
            usage();
            return error.BadArgs;
        }
    }
    return options;
}

fn usage() void {
    std.debug.print(
        \\seriallink-host --port 44126
        \\
        \\Connects to QEMU COM2 when QEMU was started with
        \\  -serial tcp:127.0.0.1:44126,server,nowait
        \\Waits for R4OS-HOST-READY, sends HOST-R4SL-HELLO,
        \\and waits for R4OS-HOST-ACK.
        \\
        \\Options:
        \\  --inject-errors      send broken R4SL test data before hello
        \\  --message TEXT       sendet vor dem Hello ein TYPE_MESSAGE-Frame
        \\
    , .{});
}

fn connectWithRetry(io: std.Io, options: Options) !net.Stream {
    var attempt: u32 = 0;
    while (attempt < options.attempts) : (attempt += 1) {
        var address = try net.IpAddress.parse(options.host, options.port);
        return address.connect(io, .{ .mode = .stream }) catch |err| {
            if (attempt + 1 >= options.attempts) return err;
            if (options.sleep_ms > 0) {
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(options.sleep_ms), .awake);
            }
            continue;
        };
    }
    return error.ConnectTimeout;
}

fn readFrame(reader: *std.Io.Reader, payload_buffer: []u8) !Frame {
    var header: [HEADER_SIZE]u8 = undefined;
    try reader.readSliceAll(&header);
    if (!std.mem.eql(u8, header[0..MAGIC.len], &MAGIC)) return error.BadMagic;
    if (header[4] != VERSION) return error.BadVersion;
    const frame_type = header[5];
    const payload_len = readLe16(header[6..8]);
    if (payload_len > MAX_PAYLOAD or payload_len > payload_buffer.len) return error.BadLength;
    const expected_sum = readLe16(header[8..10]);
    try reader.readSliceAll(payload_buffer[0..payload_len]);
    header[8] = 0;
    header[9] = 0;
    const actual_sum = checksumParts(header[0..], payload_buffer[0..payload_len]);
    if (expected_sum != actual_sum) return error.BadChecksum;
    return .{ .frame_type = frame_type, .payload = payload_buffer[0..payload_len] };
}

fn writeFrame(writer: *std.Io.Writer, frame_type: u8, payload: []const u8) !void {
    var frame: [MAX_FRAME]u8 = undefined;
    const len = try buildFrame(frame_type, payload, &frame);
    try writer.writeAll(frame[0..len]);
    try writer.flush();
}

fn writeRaw(writer: *std.Io.Writer, data: []const u8) !void {
    try writer.writeAll(data);
    try writer.flush();
}

fn injectErrors(writer: *std.Io.Writer) !void {
    try writeRaw(writer, &[_]u8{0x00});

    var bad_length: [HEADER_SIZE]u8 = undefined;
    bad_length[0] = MAGIC[0];
    bad_length[1] = MAGIC[1];
    bad_length[2] = MAGIC[2];
    bad_length[3] = MAGIC[3];
    bad_length[4] = VERSION;
    bad_length[5] = TYPE_DIAG;
    writeLe16(bad_length[6..8], @intCast(MAX_PAYLOAD + 1));
    bad_length[8] = 0;
    bad_length[9] = 0;
    try writeRaw(writer, &bad_length);

    var bad_checksum: [MAX_FRAME]u8 = undefined;
    const len = try buildFrame(TYPE_DIAG, "BAD-CHECKSUM", &bad_checksum);
    bad_checksum[8] ^= 0x5A;
    try writeRaw(writer, bad_checksum[0..len]);
}

fn buildFrame(frame_type: u8, payload: []const u8, out: []u8) !usize {
    if (payload.len > MAX_PAYLOAD or out.len < HEADER_SIZE + payload.len) return error.BadLength;
    out[0] = MAGIC[0];
    out[1] = MAGIC[1];
    out[2] = MAGIC[2];
    out[3] = MAGIC[3];
    out[4] = VERSION;
    out[5] = frame_type;
    writeLe16(out[6..8], @intCast(payload.len));
    out[8] = 0;
    out[9] = 0;
    if (payload.len != 0) @memcpy(out[HEADER_SIZE .. HEADER_SIZE + payload.len], payload);
    writeLe16(out[8..10], checksum(out[0 .. HEADER_SIZE + payload.len]));
    return HEADER_SIZE + payload.len;
}

fn expectPayload(frame: Frame, frame_type: u8, payload: []const u8) !void {
    if (frame.frame_type != frame_type) return error.UnexpectedType;
    if (!std.mem.eql(u8, frame.payload, payload)) return error.UnexpectedPayload;
}

fn payloadEquals(frame: Frame, frame_type: u8, payload: []const u8) bool {
    return frame.frame_type == frame_type and std.mem.eql(u8, frame.payload, payload);
}

fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    for (data, 0..) |byte, i| {
        if (i == 8 or i == 9) continue;
        sum += byte;
    }
    return @truncate(sum & 0xFFFF);
}

fn checksumParts(header: []const u8, payload: []const u8) u16 {
    var sum: u32 = 0;
    for (header, 0..) |byte, i| {
        if (i == 8 or i == 9) continue;
        sum += byte;
    }
    for (payload) |byte| sum += byte;
    return @truncate(sum & 0xFFFF);
}

fn readLe16(data: []const u8) u16 {
    return @as(u16, data[0]) | (@as(u16, data[1]) << 8);
}

fn writeLe16(out: []u8, value: u16) void {
    out[0] = @truncate(value & 0x00FF);
    out[1] = @truncate(value >> 8);
}
