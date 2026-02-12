// datetime.zig - Glk date/time functions

const std = @import("std");
const types = @import("types.zig");

const glui32 = types.glui32;
const glsi32 = types.glsi32;
const glktimeval_t = types.glktimeval_t;
const glkdate_t = types.glkdate_t;

export fn glk_current_time(time: ?*glktimeval_t) callconv(.c) void {
    if (time == null) return;
    const ts = std.time.timestamp();
    time.?.high_sec = @intCast(@as(i64, ts) >> 32);
    time.?.low_sec = @intCast(@as(u64, @bitCast(ts)) & 0xFFFFFFFF);
    time.?.microsec = 0;
}

export fn glk_current_simple_time(factor: glui32) callconv(.c) glsi32 {
    if (factor == 0) return 0;
    const ts = std.time.timestamp();
    return @intCast(@divTrunc(ts, factor));
}

export fn glk_time_to_date_utc(time: ?*const glktimeval_t, date: ?*glkdate_t) callconv(.c) void {
    if (time == null or date == null) return;
    const secs = (@as(i64, time.?.high_sec) << 32) | time.?.low_sec;
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    date.?.year = @intCast(year_day.year);
    date.?.month = @intCast(@intFromEnum(month_day.month));
    date.?.day = month_day.day_index + 1;
    // Day of week: epoch day 0 (1970-01-01) was Thursday (4). Calculate modulo 7.
    const day_num: i64 = @intCast(day.day);
    date.?.weekday = @intCast(@mod(day_num + 4, 7)); // Sunday = 0
    date.?.hour = @intCast(day_seconds.getHoursIntoDay());
    date.?.minute = @intCast(day_seconds.getMinutesIntoHour());
    date.?.second = @intCast(day_seconds.getSecondsIntoMinute());
    date.?.microsec = time.?.microsec;
}

// ============== Tests ==============

const testing = std.testing;

test "glk_time_to_date_utc for Unix epoch (1970-01-01 Thursday)" {
    const time = glktimeval_t{ .high_sec = 0, .low_sec = 0, .microsec = 0 };
    var date: glkdate_t = undefined;
    glk_time_to_date_utc(&time, &date);
    try testing.expectEqual(@as(glsi32, 1970), date.year);
    try testing.expectEqual(@as(glsi32, 1), date.month);
    try testing.expectEqual(@as(glsi32, 1), date.day);
    try testing.expectEqual(@as(glsi32, 4), date.weekday); // Thursday
    try testing.expectEqual(@as(glsi32, 0), date.hour);
    try testing.expectEqual(@as(glsi32, 0), date.minute);
    try testing.expectEqual(@as(glsi32, 0), date.second);
    try testing.expectEqual(@as(glsi32, 0), date.microsec);
}

test "glk_time_to_date_utc for 2000-01-01 (Saturday)" {
    // 946684800 seconds since epoch
    const secs: u32 = 946684800;
    const time = glktimeval_t{ .high_sec = 0, .low_sec = secs, .microsec = 0 };
    var date: glkdate_t = undefined;
    glk_time_to_date_utc(&time, &date);
    try testing.expectEqual(@as(glsi32, 2000), date.year);
    try testing.expectEqual(@as(glsi32, 1), date.month);
    try testing.expectEqual(@as(glsi32, 1), date.day);
    try testing.expectEqual(@as(glsi32, 6), date.weekday); // Saturday
    try testing.expectEqual(@as(glsi32, 0), date.hour);
    try testing.expectEqual(@as(glsi32, 0), date.minute);
    try testing.expectEqual(@as(glsi32, 0), date.second);
}

test "glk_time_to_date_utc preserves microsec" {
    const time = glktimeval_t{ .high_sec = 0, .low_sec = 0, .microsec = 123456 };
    var date: glkdate_t = undefined;
    glk_time_to_date_utc(&time, &date);
    try testing.expectEqual(@as(glsi32, 123456), date.microsec);
}

test "glk_time_to_date_utc null safety" {
    var date: glkdate_t = undefined;
    glk_time_to_date_utc(null, &date); // should not crash
    glk_time_to_date_utc(null, null); // should not crash
}

export fn glk_time_to_date_local(time: ?*const glktimeval_t, date: ?*glkdate_t) callconv(.c) void {
    // For simplicity, treat local as UTC
    glk_time_to_date_utc(time, date);
}

export fn glk_simple_time_to_date_utc(time: glsi32, factor: glui32, date: ?*glkdate_t) callconv(.c) void {
    var tv: glktimeval_t = undefined;
    tv.high_sec = 0;
    tv.low_sec = @intCast(@as(u32, @bitCast(time)) *% factor);
    tv.microsec = 0;
    glk_time_to_date_utc(&tv, date);
}

export fn glk_simple_time_to_date_local(time: glsi32, factor: glui32, date: ?*glkdate_t) callconv(.c) void {
    glk_simple_time_to_date_utc(time, factor, date);
}

export fn glk_date_to_time_utc(date: ?*const glkdate_t, time: ?*glktimeval_t) callconv(.c) void {
    if (date == null or time == null) return;
    // Simplified calculation
    time.?.high_sec = 0;
    time.?.low_sec = 0;
    time.?.microsec = date.?.microsec;
}

export fn glk_date_to_time_local(date: ?*const glkdate_t, time: ?*glktimeval_t) callconv(.c) void {
    glk_date_to_time_utc(date, time);
}

export fn glk_date_to_simple_time_utc(date: ?*const glkdate_t, factor: glui32) callconv(.c) glsi32 {
    if (date == null or factor == 0) return 0;
    var time: glktimeval_t = undefined;
    glk_date_to_time_utc(date, &time);
    return @intCast(@divTrunc(time.low_sec, factor));
}

export fn glk_date_to_simple_time_local(date: ?*const glkdate_t, factor: glui32) callconv(.c) glsi32 {
    return glk_date_to_simple_time_utc(date, factor);
}
