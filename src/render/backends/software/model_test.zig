//! Geometry models in the software renderer: transforms, clipping, the shading modes and the resulting pixels.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");

const texture = @import("../../../assets/texture.zig");
const camera = @import("camera.zig");
const m = @import("math.zig");
const model = @import("model.zig");

test "3DO transforms match the reference render arithmetic" {
    const angles = camera.Angles.init();
    const rotations = [_][3]i16{ .{ 0, 0, 0 }, .{ 1024, 2048, -512 }, .{ -2048, 5341, 4000 } };
    const expected = [_][9]u32{
        .{
            0x3f800000,
            0xb3a4ea70,
            0x33a4ea71,
            0x33a4ea71,
            0x3f800000,
            0xb3a4ea71,
            0xb3a4ea70,
            0x33a4ea71,
            0x3f800000,
        },
        .{
            0x3f2406ce,
            0x3ece83ad,
            0x3f273d75,
            0xbe3890d6,
            0x3f67f7f8,
            0xbec3ef17,
            0xbf3f0e3d,
            0x3e0281f6,
            0x3f273d75,
        },
        .{
            0xbf24ff25,
            0x3edf4728,
            0x3f20c697,
            0x3f34e58d,
            0x3cd535ed,
            0x3f3504f4,
            0x3e95832e,
            0x3f664762,
            0xbea65cef,
        },
    };

    for (rotations, expected) |a, e| {
        const matrix = model.rotation(
            &angles,
            .{ .position = .{ .x = 0, .y = 0, .z = 0 }, .pitch = a[0], .yaw = a[1], .roll = a[2] },
        );

        for (matrix, e) |actual, wanted| try std.testing.expectEqual(
            wanted,
            @as(u32, @bitCast(actual)),
        );
    }
}

test "3DO polygon clipping and four shading modes match the reference pixels" {
    const a = std.testing.allocator;
    const angles = camera.Angles.init();
    var view = try camera.View.init(a, &angles, 64, 48);
    defer view.deinit(a);
    const shapes = [_][4][3]f32{
        .{
            .{ -3.25, -2.75, 7.25 },
            .{ 3.5, -2.25, 8.5 },
            .{ 3.25, 3.5, 10.25 },
            .{ -2.75, 2.5, 6.75 },
        },
        .{
            .{ -10.25, -5.75, 0.25 },
            .{ 7.5, -4.25, 5.5 },
            .{ 8.25, 10.5, 10.25 },
            .{ -5.75, 7.5, 6.75 },
        },
        .{ .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } },
    };

    const expected = [_][2][]const u8{
        .{
            "552da6838c0e9dfb79cb52141b876806db0c6d657260c234033c40909a4307f3",
            "eb8ecac5dad30d2e386e9c1e74d6ddac6bb85b73f99b2113a1327e6a9c25e037",
        },
        .{
            "552da6838c0e9dfb79cb52141b876806db0c6d657260c234033c40909a4307f3",
            "d4c6738495efdb0b5938dcde13258cde579680d90b968be0c1003d8ecfed0162",
        },
        .{
            "1e37a283b8fdebbcbe21a02a35a4af49318279e3677e784d77c837cf0315abbd",
            "2cf28fadfe9130e654018932a6903b826eaf22fbda00d9cbbcdb146272170792",
        },
        .{
            "c34541cf33fbdf1a52507aa1f7083cc59a142bd74e314d3958b7a18256d3d003",
            "0582e351b5625ad88109a543f9b7a4e40eee41aa190ed62c4e2768817ecc3ae8",
        },
        .{
            "231ceaea45113ac29241a066c064871aecd5cb73b7e566938e2b76363a957141",
            "0582e351b5625ad88109a543f9b7a4e40eee41aa190ed62c4e2768817ecc3ae8",
        },
        .{
            "bc2073a328e1f191dd919484e1fb93bbe982229ab0a04bb604b8f6158c78ab13",
            "0582e351b5625ad88109a543f9b7a4e40eee41aa190ed62c4e2768817ecc3ae8",
        },
        .{
            "d39a8a399aa3149458fc6454784eac8bffcf0853ef9faeb397889cfa95cc0065",
            "fd506249f5cae3286966e6ea866072a05faae26eef4841b3d92ee07a2035d909",
        },
        .{
            "d39a8a399aa3149458fc6454784eac8bffcf0853ef9faeb397889cfa95cc0065",
            "2213864e2ee86168d1b8f41eea385e287403f4c86df16e9769a4e171cd13b254",
        },
        .{
            "f6e261adb25d6c81b27f06bdb50382c67e35105010a3a55ac1286ae162b51920",
            "074ef94711d9cd39279afdeac334a7ee777fb64aa9cc3092cd5cb15fe583f5c0",
        },
        .{
            "d8c6a38165ba5585188bc814c583150552933bc898ab77168fc69a920732a1c2",
            "153af38b73c96593c168fb46c4637293775c0fd751764ebbe0cc27113ee6539a",
        },
        .{
            "200dcaa05a3b133d32af808ed759a24fc4a1e6b8c739c62ee2315c1a5f841f93",
            "e07826e9c563175c145edb25cecab1e2cf86a8eda82cb717d3c4f03dae7c33f1",
        },
        .{
            "a7876bf0d94bfa47001b08781b516377a3c4fea164323aac6cdb796d34448cf5",
            "bc4b405481251f561185965fec56d29008543390ea3cd8cc23f72006d15cf46a",
        },
        .{
            "426bbadb829f825091b0d1329212fd41af1780dc7638888c7aead39cc2fd9386",
            "839a207f4a95b8696dbb3ff28356f67102f013b74c4560394c3e9a5538c37f43",
        },
        .{
            "426bbadb829f825091b0d1329212fd41af1780dc7638888c7aead39cc2fd9386",
            "6732c92ce8b40f2883b2ef1ace88f477486d2b0d8b663e04be6a04caa0047810",
        },
        .{
            "e2b7f0c914cc751a4b8663107a32bec5b50e1fc5b39cf01d90239e4decf2eee1",
            "c3949c09e14127492731cdb1f3bdc1ac950eed3ae6be6a48d461f86bc1daf36f",
        },
        .{
            "6f1dc41cda5eaa612eeb6430452bcbdc328b2848922b17c3272861ab0977c50f",
            "bc669b55affc3fc6598b8c2f217ea2d4f59f5104672fb16030bc2fbbb6a1a343",
        },
        .{
            "5f8baa10ac33a002fea34d999739a37a7c2e17b02352187080bb0e6d766b2ecc",
            "903562510fab236738ca1c2f29e7a4514abfbd7d7ed8b7db3187b2e649f9cc08",
        },
        .{
            "95d7a461f8d17b372112d728a1fecadb56113e2c2eaa1dd2d8761af0bec3ce9f",
            "82572a29fce94618a273be6a89e0ce4afc5fb45686f9802becf7a8d793b3c32c",
        },
        .{
            "3ffeee0bcb89ca32544634223ee7964a7fc2d6cb5cdd33ccf2fd9470a16cb8c3",
            "230d0a3a37b110621b416ef2186faaa0d3525e4a49c6d7fbbc16f9032191f60a",
        },
        .{
            "3ffeee0bcb89ca32544634223ee7964a7fc2d6cb5cdd33ccf2fd9470a16cb8c3",
            "8845f1beb485c3aa4f59825abfeefee8c165ccfab6683ace74e5ae974a35cce8",
        },
        .{
            "30d029bf016fa93a7f11cbaff80652720a1f9e79279388f611ce7cfa9ab74aa6",
            "142331e1923a8bd7e79e3b71332606983a2bc904249c3e74f0273c7385d6f342",
        },
        .{
            "e72dcab27fad7f6fdfc862713e1315f32ccb7ff02d781e16de457a554ef47319",
            "96e95bd269230e7c57afb1430b89a8b60f67078171b21ec48588a26ded72d2fb",
        },
        .{
            "3c026d61ebf730390761b6f2d6ff156c27f6c458deaaf6242122cd024b939987",
            "0724527d5c9fd5d32d84774f5a176c5f1b5f2184b92d9dab624e1a1da1b876bf",
        },
        .{
            "c1d3369470a1965c4d453ff76f46a3052ece8105855b4b9fb3977b8f2fc969b6",
            "bc961faa849a9074fbabcaae2ae71818eae34d9d8695c609a89567083b7a7715",
        },
    };

    var top: [64]i16 = undefined;
    var bottom: [64]i16 = undefined;
    var depth: [64]i16 = undefined;

    for (0..64) |x| {
        top[x] = @intCast(3 + x % 5);
        bottom[x] = @intCast(44 - x % 7);
        depth[x] = if (x % 7 == 0) 100 else 320;
    }

    var cmap: [8192]u8 = undefined;

    for (&cmap, 0..) |*byte, i| byte.* = @truncate(i * 13 + i / 256 * 7);

    var dmap: [128]u8 = undefined;

    for (&dmap, 0..) |*byte, i| byte.* = @intCast(@min(31, i / 4));

    var texels: [64]u8 = undefined;

    for (&texels, 0..) |*byte, i| byte.* = @truncate(i * 17);

    const tex = texture.Texture{
        .width = 8,
        .height = 8,
        .pixels = &texels,
        .height_shift = 3,
        .flags = .{},
    };

    var pixels: [64 * 48]u8 = undefined;
    var case: usize = 0;

    for (0..4) |mode| for (shapes) |shape| {
        for ([_]i16{ 0, 512 }) |pitch| {
            view.setPose(&angles, 0, 0, 0, 0, pitch);
            var input: [4]model.Vertex = undefined;

            for (shape, &input, 0..) |point, *vertex, i| vertex.* = .{
                .position = .{ .x = point[0], .y = point[1], .z = point[2] },
                .uv = .{
                    .x = @as(f32, @floatFromInt(i % 2)) * 7.875,
                    .y = @as(f32, @floatFromInt(i / 2)) * 7.875,
                },
                .shade = @as(f32, @floatFromInt(i)) * 6.75 + 0.25,
            };

            var clipped: [32]model.Vertex = undefined;
            const n = try model.clip(&view, &input, &clipped);
            var hash = std.crypto.hash.sha2.Sha256.init(.{});

            for (clipped[0..n]) |v| for ([_]f32{ v.position.x, v.position.y, v.position.z }) |f| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(f), .little);
                hash.update(&b);
            };

            if (mode & 2 != 0) for (clipped[0..n]) |v| for ([_]f32{ v.uv.x, v.uv.y }) |f| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(f), .little);
                hash.update(&b);
            };

            if (mode & 1 != 0) for (clipped[0..n]) |v| {
                var b: [4]u8 = undefined;
                std.mem.writeInt(u32, &b, @bitCast(v.shade), .little);
                hash.update(&b);
            };

            var actual: [32]u8 = undefined;
            hash.final(&actual);
            var wanted: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&wanted, expected[case][0]);
            std.testing.expectEqualSlices(u8, &wanted, &actual) catch |err| {
                std.debug.print(
                    "clipping case {d} mode {d} pitch {d} count {d}\n",
                    .{ case, mode, pitch, n },
                );

                return err;
            };

            var projected: [32]model.Projected = undefined;

            for (clipped[0..n], projected[0..n]) |v, *p| p.* = model.project(&view, v);

            for (&pixels, 0..) |*byte, i| byte.* = @truncate(i * 29);

            const ctx = model.Context{
                .view = &view,
                .angles = &angles,
                .pixels = &pixels,
                .window = .{
                    .left = 8,
                    .right = 56,
                    .top = 3,
                    .bottom = 44,
                    .inner_top = 3,
                    .inner_bottom = 44,
                    .top_clip = &top,
                    .bottom_clip = &bottom,
                },
                .depth = &depth,
                .lighting = .{
                    .force_depth = 0,
                    .depth_bias = 0,
                    .depth_strength = 0,
                    .ambient_bias = 0,
                    .ambient = 20,
                    .ambient_min = 17,
                    .color_map = &cmap,
                    .depth_map = &dmap,
                },
            };

            try model.raster(
                ctx,
                projected[0..n],
                @intCast(mode),
                153,
                if (mode & 2 != 0) &tex else null,
                if (mode == 2) cmap[3 * 256 ..][0..256] else null,
            );

            std.crypto.hash.sha2.Sha256.hash(&pixels, &actual, .{});

            _ = try std.fmt.hexToBytes(&wanted, expected[case][1]);
            std.testing.expectEqualSlices(u8, &wanted, &actual) catch |err| {
                std.debug.print(
                    "raster case {d} mode {d} pitch {d} count {d}\n",
                    .{ case, mode, pitch, n },
                );

                return err;
            };

            case += 1;
        }
    };
}

test "3DO model assets render with lighting and pixel hashes" {
    const lab = @import("../../../assets/lab.zig");
    const assets = @import("../../../assets/model.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var archives: [2]lab.Archive = undefined;

    for ([_][]const u8{ "OLOBJ", "OLTEX" }, &archives) |name, *out| {
        const path = try std.fmt.allocPrint(a, "inputs/OUTLAWS_CD1/OUTLAWS/{s}.LAB", .{name});
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            a,
            .limited(64 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => return err,
        };

        out.* = try lab.Archive.init(bytes);
    }

    const angles = camera.Angles.init();
    var view = try camera.View.init(a, &angles, 64, 48);
    const names = [_][]const u8{
        "GDYNAM.3DO",
        "GKNIFE.3DO",
        "GGATGUN.3DO",
        "MINECAR.3DO",
        "QUADCUBE.3DO",
    };

    const expected = [_][2][]const u8{
        .{
            "43ee34506abcc5028d732e15687a3b91e44389e47c31d9c87ae059ae97813e23",
            "949128a489f494f6ba2c9b512d8978695454a6923a19a2b42f088a19962caceb",
        },
        .{
            "8d50584ea42a57d5ec71ddc9d824e9f0a87d73ad58982f7f0979a09e3b41c642",
            "a43daac0564e9b96ea8098b8b9b2866f4c93b622ec0d241031e45b2441c92218",
        },
        .{
            "2075c831e932e97eb3cbe8752c28008b295f737813dabbaad75e68a06b215f7f",
            "dd33616f98f0a677547dd423118132b90b8562e5ad460743d740bef8c75ba68c",
        },
        .{
            "3c24d417aeecfb6ecad4a8b1358723194931035337550c6d4b303bbb7dbfdebc",
            "0cf9d0b9ae81805d1b52b61f3c69f3de49b3783b1bc2ddc04cd3cb2ec231a539",
        },
        .{
            "eab93c9207b0b473ce6ba42f86393e7be0bf60ca058a0ab1ca6552dcac72e5ff",
            "b9ab2cb762d208c2d1b4a1febb0eb48b7a321d3ddc0ab451a32435950158e0f0",
        },
    };

    var top: [64]i16 = undefined;
    var bottom: [64]i16 = undefined;
    var depth: [64]i16 = undefined;

    for (0..64) |x| {
        top[x] = @intCast(3 + x % 5);
        bottom[x] = @intCast(44 - x % 7);
        depth[x] = if (x % 7 == 0) 100 else 320;
    }

    var cmap: [8192]u8 = undefined;

    for (&cmap, 0..) |*byte, i| byte.* = @truncate(i * 13 + i / 256 * 7);

    var dmap: [128]u8 = undefined;

    for (&dmap, 0..) |*byte, i| byte.* = @intCast(@min(31, i / 4));

    var pixels: [64 * 48]u8 = undefined;

    for (names, expected) |name, hashes| {
        var resource = try assets.Model.parse(a, try archives[0].find(name, 0), &archives);
        defer resource.deinit();

        for (hashes, 0..) |expected_hash, case| {
            view.setPose(
                &angles,
                if (case != 0) 2 else 0,
                if (case != 0) 3 else 0,
                if (case != 0) -5 else 0,
                if (case != 0) 512 else 0,
                if (case != 0) 256 else 0,
            );

            for (&pixels, 0..) |*byte, i| byte.* = @truncate(i * 29);

            const ctx = model.Context{
                .view = &view,
                .angles = &angles,
                .pixels = &pixels,
                .window = .{
                    .left = 8,
                    .right = 56,
                    .top = 3,
                    .bottom = 44,
                    .inner_top = 3,
                    .inner_bottom = 44,
                    .top_clip = &top,
                    .bottom_clip = &bottom,
                },
                .depth = &depth,
                .lighting = .{
                    .force_depth = @intCast(case),
                    .depth_bias = if (case != 0) -2 else 0,
                    .depth_strength = if (case != 0) 11 else 0,
                    .ambient_bias = 0,
                    .ambient = 20,
                    .ambient_min = 17,
                    .color_map = &cmap,
                    .depth_map = &dmap,
                },
            };

            try model.draw(
                ctx,
                &resource,
                .{
                    .position = .{ .x = 0, .y = 1, .z = 7 },
                    .pitch = if (case != 0) 1024 else 0,
                    .yaw = if (case != 0) 2048 else 0,
                    .roll = if (case != 0) -512 else 0,
                },
            );

            var actual: [32]u8 = undefined;
            var wanted: [32]u8 = undefined;

            std.crypto.hash.sha2.Sha256.hash(&pixels, &actual, .{});
            _ = try std.fmt.hexToBytes(&wanted, expected_hash);
            std.testing.expectEqualSlices(u8, &wanted, &actual) catch |err| {
                std.debug.print("model {s} case {d}\n", .{ name, case });
                return err;
            };
        }
    }
}

test "3DO model sphere culling matches collection and dynamic windows" {
    const a = std.testing.allocator;
    const angles = camera.Angles.init();
    const view = try camera.View.init(a, &angles, 64, 48);
    defer view.deinit(a);
    const values = [_]struct { point: [3]f32, radius: f32, static: bool, dynamic: bool }{
        .{ .point = .{ -10, 0, 1 }, .radius = 2, .static = false, .dynamic = false },
        .{ .point = .{ -4, 0, 0.5 }, .radius = 3, .static = true, .dynamic = true },
        .{ .point = .{ 0, 0, -2 }, .radius = 3, .static = true, .dynamic = true },
        .{ .point = .{ 0, 0, -2.25 }, .radius = 3, .static = false, .dynamic = false },
        .{ .point = .{ 0, 0, 0.5 }, .radius = 0.5, .static = true, .dynamic = true },
        .{ .point = .{ 0, 0, 0.49 }, .radius = 0.5, .static = false, .dynamic = false },
        .{ .point = .{ 20, 0, 10 }, .radius = 2, .static = false, .dynamic = false },
        .{ .point = .{ 6, 0, 8 }, .radius = 1, .static = true, .dynamic = true },
        .{ .point = .{ -6, 0, 8 }, .radius = 1, .static = true, .dynamic = true },
        .{ .point = .{ 0, 0, 2 }, .radius = 3, .static = true, .dynamic = true },
        .{ .point = .{ 0, 0, 2 }, .radius = 0, .static = true, .dynamic = true },
        .{ .point = .{ -8, 0, 8 }, .radius = 0, .static = true, .dynamic = false },
    };

    for (values) |v| {
        const point = @import(
            "../../../assets/level.zig",
        ).Vec3{ .x = v.point[0], .y = v.point[1], .z = v.point[2] };

        try std.testing.expectEqual(
            v.static,
            model.eligible(&view, point, v.radius, view.left, view.right),
        );

        try std.testing.expectEqual(v.dynamic, model.eligible(&view, point, v.radius, 8, 56));
    }
}
