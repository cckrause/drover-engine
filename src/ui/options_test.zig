//! The options page: frames, focus, the settings it writes and the sounds it plays.
//!
//! Checked against generated reference fixtures; skips when they are not
//! installed (see testing/fixtures.zig).

const std = @import("std");
const lab = @import("../assets/lab.zig");
const pcx = @import("../assets/pcx.zig");
const nwx = @import("../assets/nwx.zig");
const dialog = @import("dialog.zig");
const options = @import("options.zig");
const settings = @import("../settings.zig");
const display_palette = @import("../render/display_palette.zig");
const view_box = @import("../render/view_box.zig");

const cases = [_]Case{
    .{
        .name = "keyboard_focus",
        .events = &.{ .{ .now = 0 }, .{ .key = 0xf, .now = 10 }, .{ .key = 0xf, .now = 20 }, .{ .key = 0xf, .shift = true, .now = 30 }, .{ .key = 0x50, .now = 40 }, .{ .key = 0x50, .now = 50 }, .{ .key = 0x4d, .now = 60 }, .{ .key = 0x48, .now = 70 }, .{ .key = 0x4b, .now = 80 }, .{ .key = 0x48, .now = 90 }, .{ .key = 0x48, .now = 100 } },
        .frames = &.{
            .{ .focus = 0xa, .view_box = 14, .gamma = 0, .running = true, .pixels = "e6f78c734def52205bad7ed63e413e1ffc025916f5f4fd11e8f06001ec7d182b", .palette = "ec582902282e9ce1303f0da3ef8db3a0899bde4a7aeb6b98d2db9595b114793c", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0x4, .view_box = 14, .gamma = 0, .running = true, .pixels = "a2cf1c9b69cbf56f8511c327565c1722ce2e3cbaae55bf2798e35e2930827aed", .palette = "fa07e984366c029265dc4f09eb23eb20b9eed21cb0101221015111fa226539ee", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0x5, .view_box = 14, .gamma = 0, .running = true, .pixels = "b01d033cbe8abbc5f4f29de091e4da66163efe536f28c759e7092b952e05a391", .palette = "dc5b7a775aff01b11536864309d585c803a80c8e9019a076e60a4a2ad9e30448", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0x4, .view_box = 14, .gamma = 0, .running = true, .pixels = "a2cf1c9b69cbf56f8511c327565c1722ce2e3cbaae55bf2798e35e2930827aed", .palette = "e6f30796b42f1d39c4d6413feea2abf58e8acbba2179c76e1b80ac1ce83dec84", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0x5, .view_box = 14, .gamma = 0, .running = true, .pixels = "b01d033cbe8abbc5f4f29de091e4da66163efe536f28c759e7092b952e05a391", .palette = "dfc65576995a7441d8b84d3c6aafb9b06a4e668afc9dc0b72fd64a5cd78da8ab", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0x4, .view_box = 14, .gamma = 0, .running = true, .pixels = "a2cf1c9b69cbf56f8511c327565c1722ce2e3cbaae55bf2798e35e2930827aed", .palette = "92934585759d6c22719ae725765a55eafdcb8e898e8ce8b1d59f0801c8dde881", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0x6, .view_box = 14, .gamma = 0, .running = true, .pixels = "0ed06483afb6449bea8daea39e2f0aa672c5aa19b6d50c9b94a6062ca9c75b16", .palette = "a1ab11892a01fe446913e5fa1d73c66847573a2314e91277cffca70205945e87", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 14, .gamma = 0, .running = true, .pixels = "e6f78c734def52205bad7ed63e413e1ffc025916f5f4fd11e8f06001ec7d182b", .palette = "d814af13c1b52d9fa23908488941a2a889a5c7601a1bf807cdc8098f37fa28e1", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 13, .gamma = 0, .running = true, .pixels = "1fdc4dd60313cd0ce603998fc5b2d14540d39020e95211a8327873a9db7a702c", .palette = "e2e0733969ffb9368b3a5f0bcc743612d24f9551551721b8530895efdcc75f85", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0x10000, .view_box = 13, .gamma = 0, .running = true, .pixels = "b1686fd30526f0b198b088b7dba0f7703511fddb5e8fe1c64c8f761351e810b3", .palette = "12043de71a12100d2c26f48273310254fa32e6013c0e1f493a4954adfee93a9f", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xe, .view_box = 13, .gamma = 0, .running = true, .pixels = "897685f2de23d25eac4f93fcf78041cbb06eeef8c068ea5506dfc8192b39bd9c", .palette = "498e44c1c1279ba17ab5b12e9f0a627e389a4b519d3975d48b54bc0bb4f87fb0", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
        },
        .sounds = &.{ -1, 1, 2, 3, 4, 5, 6, 7, 9, 10 },
        .writes = 5,
        .registry = &.{ .{ "View Box", "13" }, .{ "Gamma", "0" } },
        .views = 4,
        .view = .{ 0, 20, 640, 400 },
    },
    .{
        .name = "screen_size_keys",
        .events = &.{ .{ .now = 0 }, .{ .key = 0x4d, .now = 100 }, .{ .key = 0x4d, .now = 150 }, .{ .key = 0x4b, .now = 200 }, .{ .key = 0x47, .now = 250 }, .{ .key = 0x4f, .now = 300 }, .{ .key = 0x49, .now = 350 }, .{ .key = 0x51, .now = 400 }, .{ .key = 0x51, .now = 410 } },
        .frames = &.{
            .{ .focus = 0xa, .view_box = 14, .gamma = 0, .running = true, .pixels = "e6f78c734def52205bad7ed63e413e1ffc025916f5f4fd11e8f06001ec7d182b", .palette = "ec582902282e9ce1303f0da3ef8db3a0899bde4a7aeb6b98d2db9595b114793c", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 15, .gamma = 0, .running = true, .pixels = "a3a51b7dadefe1a34cb6b6865bcdce9920ad248fb8196fc9f687e9aa2815a19e", .palette = "498e44c1c1279ba17ab5b12e9f0a627e389a4b519d3975d48b54bc0bb4f87fb0", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 16, .gamma = 0, .running = true, .pixels = "38c1401fec89c4a73d3d30fd433eeedf560ba2cf40cb820d45d3b3ffe810d35a", .palette = "92934585759d6c22719ae725765a55eafdcb8e898e8ce8b1d59f0801c8dde881", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 15, .gamma = 0, .running = true, .pixels = "a3a51b7dadefe1a34cb6b6865bcdce9920ad248fb8196fc9f687e9aa2815a19e", .palette = "ec582902282e9ce1303f0da3ef8db3a0899bde4a7aeb6b98d2db9595b114793c", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 1, .gamma = 0, .running = true, .pixels = "ba7556fba1b8249b27ce4d9215f0de3376d46a0a0815dc1e3791ceb636bfce71", .palette = "92934585759d6c22719ae725765a55eafdcb8e898e8ce8b1d59f0801c8dde881", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 16, .gamma = 0, .running = true, .pixels = "38c1401fec89c4a73d3d30fd433eeedf560ba2cf40cb820d45d3b3ffe810d35a", .palette = "498e44c1c1279ba17ab5b12e9f0a627e389a4b519d3975d48b54bc0bb4f87fb0", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 11, .gamma = 0, .running = true, .pixels = "3f1198c1da52893a9f8c33a7ed1e265fa4b1b372a391ca93faffb96633dc9b85", .palette = "92934585759d6c22719ae725765a55eafdcb8e898e8ce8b1d59f0801c8dde881", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 16, .gamma = 0, .running = true, .pixels = "38c1401fec89c4a73d3d30fd433eeedf560ba2cf40cb820d45d3b3ffe810d35a", .palette = "ec582902282e9ce1303f0da3ef8db3a0899bde4a7aeb6b98d2db9595b114793c", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xa, .view_box = 16, .gamma = 0, .running = true, .pixels = "38c1401fec89c4a73d3d30fd433eeedf560ba2cf40cb820d45d3b3ffe810d35a", .palette = "fa07e984366c029265dc4f09eb23eb20b9eed21cb0101221015111fa226539ee", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
        },
        .sounds = &.{-1},
        .writes = 10,
        .registry = &.{ .{ "View Box", "16" }, .{ "Gamma", "0" } },
        .views = 9,
        .view = .{ 0, 0, 640, 480 },
    },
    .{
        .name = "gamma_keys_cancel",
        .events = &.{ .{ .now = 0 }, .{ .key = 0x50, .now = 20 }, .{ .key = 0x4d, .now = 40 }, .{ .key = 0x4d, .now = 60 }, .{ .key = 0x4f, .now = 80 }, .{ .key = 0x47, .now = 100 }, .{ .key = 0x1, .now = 120 } },
        .frames = &.{
            .{ .focus = 0xa, .view_box = 14, .gamma = 0, .running = true, .pixels = "e6f78c734def52205bad7ed63e413e1ffc025916f5f4fd11e8f06001ec7d182b", .palette = "ec582902282e9ce1303f0da3ef8db3a0899bde4a7aeb6b98d2db9595b114793c", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 0, .running = true, .pixels = "a339a7dcb8b3ea5562aaead8327ec3336f3af037e8a1fe357608a3904df53900", .palette = "dc5b7a775aff01b11536864309d585c803a80c8e9019a076e60a4a2ad9e30448", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 1, .running = true, .pixels = "8d82b21581a54df859e6cd75305f82daf839b56858f3c9d9a0a8bb3b0391d9fa", .palette = "dfc65576995a7441d8b84d3c6aafb9b06a4e668afc9dc0b72fd64a5cd78da8ab", .table = "42aca0c4023a9328ecd11a7925fc7beabf259308b369fdc6ced280028dbfc200" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 2, .running = true, .pixels = "6bab64272ee142543aafd02a53cfdd9b3bc3bc21d5381ac156a824d975f998e3", .palette = "a1ab11892a01fe446913e5fa1d73c66847573a2314e91277cffca70205945e87", .table = "bb06f97ebcd70eec2d8a8cdbc78def15300ee2ef902a5259821fb682fcac7b0a" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 4, .running = true, .pixels = "89a5f64c76080bb932c9aa8c91532d9099b042f2adb90f2820c1f4629fadca24", .palette = "e2e0733969ffb9368b3a5f0bcc743612d24f9551551721b8530895efdcc75f85", .table = "fea78d51aad8e3e636dde9ad1339ac90c91d4586644de800ace70775e61347ab" },
            .{ .focus = 0xe, .view_box = 14, .gamma = -4, .running = true, .pixels = "be10c99d02be2e4878726d71e4eb929a7c0f573b12ba1748f089d29ef028c848", .palette = "498e44c1c1279ba17ab5b12e9f0a627e389a4b519d3975d48b54bc0bb4f87fb0", .table = "a86e447adc41ec84f47a12ae2106ba738ccb81be2e839ddf8b5bc23ef4bdef2f" },
            .{ .focus = 0xe, .view_box = 14, .gamma = -4, .running = false, .pixels = "90f6820ed1bf24965ed28fc560d4e8ad8aa2d52d7c6323cf7fb9e18463d50cf9", .palette = "e2e0733969ffb9368b3a5f0bcc743612d24f9551551721b8530895efdcc75f85", .table = "a86e447adc41ec84f47a12ae2106ba738ccb81be2e839ddf8b5bc23ef4bdef2f" },
        },
        .sounds = &.{ -1, 1 },
        .writes = 9,
        .registry = &.{ .{ "View Box", "14" }, .{ "Gamma", "-4" } },
        .views = 2,
        .view = .{ 0, 0, 640, 440 },
        .exit = -1,
    },
    .{
        .name = "gamma_drag",
        .events = &.{ .{ .mouse = .{ 100, 100, 0 }, .now = 0 }, .{ .mouse = .{ 300, 392, 0 }, .now = 20 }, .{ .mouse = .{ 300, 392, 1 }, .now = 40 }, .{ .mouse = .{ 420, 392, 1 }, .now = 60 }, .{ .mouse = .{ 560, 392, 1 }, .now = 80 }, .{ .mouse = .{ 560, 392, 0 }, .now = 100 }, .{ .mouse = .{ 250, 392, 0 }, .now = 120 }, .{ .key = 0x4d, .now = 140 }, .{ .key = 0x1c, .now = 160 } },
        .frames = &.{
            .{ .focus = 0xa, .view_box = 14, .gamma = 0, .running = true, .pixels = "23e38d540a7a7db70a0690aa40c015b67756670bdd9464859a1058ae0e8a5223", .palette = "ec582902282e9ce1303f0da3ef8db3a0899bde4a7aeb6b98d2db9595b114793c", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 0, .running = true, .pixels = "c102984972ad12d599de4a0d1a21aec975c3eed8f036dccd8c57c5c92a785443", .palette = "dc5b7a775aff01b11536864309d585c803a80c8e9019a076e60a4a2ad9e30448", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 0, .running = true, .pixels = "c102984972ad12d599de4a0d1a21aec975c3eed8f036dccd8c57c5c92a785443", .palette = "dfc65576995a7441d8b84d3c6aafb9b06a4e668afc9dc0b72fd64a5cd78da8ab", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 0, .running = true, .pixels = "9a5c123896a3da77863e8705e6b5e743ca2954b0240b692b4e9b8c9343af1e1e", .palette = "a1ab11892a01fe446913e5fa1d73c66847573a2314e91277cffca70205945e87", .table = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 4, .running = true, .pixels = "e8b1608777fbe42f575f12a6e188c1e2c15c26bc78065167bb00ec59d51af5de", .palette = "e2e0733969ffb9368b3a5f0bcc743612d24f9551551721b8530895efdcc75f85", .table = "fea78d51aad8e3e636dde9ad1339ac90c91d4586644de800ace70775e61347ab" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 4, .running = true, .pixels = "e8b1608777fbe42f575f12a6e188c1e2c15c26bc78065167bb00ec59d51af5de", .palette = "498e44c1c1279ba17ab5b12e9f0a627e389a4b519d3975d48b54bc0bb4f87fb0", .table = "fea78d51aad8e3e636dde9ad1339ac90c91d4586644de800ace70775e61347ab" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 4, .running = true, .pixels = "23db02d630985dbbc3fb8a2f6a61266b0f767615e8a5c53cca020d9046d8a916", .palette = "e2e0733969ffb9368b3a5f0bcc743612d24f9551551721b8530895efdcc75f85", .table = "fea78d51aad8e3e636dde9ad1339ac90c91d4586644de800ace70775e61347ab" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 4, .running = true, .pixels = "23db02d630985dbbc3fb8a2f6a61266b0f767615e8a5c53cca020d9046d8a916", .palette = "a1ab11892a01fe446913e5fa1d73c66847573a2314e91277cffca70205945e87", .table = "fea78d51aad8e3e636dde9ad1339ac90c91d4586644de800ace70775e61347ab" },
            .{ .focus = 0xe, .view_box = 14, .gamma = 4, .running = true, .pixels = "23db02d630985dbbc3fb8a2f6a61266b0f767615e8a5c53cca020d9046d8a916", .palette = "dfc65576995a7441d8b84d3c6aafb9b06a4e668afc9dc0b72fd64a5cd78da8ab", .table = "fea78d51aad8e3e636dde9ad1339ac90c91d4586644de800ace70775e61347ab" },
        },
        .sounds = &.{ -1, 1, 7 },
        .writes = 5,
        .registry = &.{ .{ "View Box", "14" }, .{ "Gamma", "4" } },
        .views = 1,
        .view = .{ 0, 0, 640, 440 },
    },
    .{
        .name = "done_click",
        .view_box = 9,
        .gamma = 2,
        .events = &.{ .{ .mouse = .{ 100, 300, 0 }, .now = 0 }, .{ .mouse = .{ 100, 340, 0 }, .now = 10 }, .{ .mouse = .{ 400, 310, 0 }, .now = 20 }, .{ .mouse = .{ 520, 440, 0 }, .now = 30 }, .{ .mouse = .{ 520, 440, 1 }, .now = 40 }, .{ .mouse = .{ 520, 440, 0 }, .now = 50 } },
        .frames = &.{
            .{ .focus = 0x4, .view_box = 9, .gamma = 2, .running = true, .pixels = "4521935e91f36866d327eaf2124188e4bad9cd0f65b40c0d7e7c886f83329b89", .palette = "ec582902282e9ce1303f0da3ef8db3a0899bde4a7aeb6b98d2db9595b114793c", .table = "bb06f97ebcd70eec2d8a8cdbc78def15300ee2ef902a5259821fb682fcac7b0a" },
            .{ .focus = 0x5, .view_box = 9, .gamma = 2, .running = true, .pixels = "dddd5fb25e1b9714329f36ccffcb01a15220c876187c4badba38d90b2811f40c", .palette = "fa07e984366c029265dc4f09eb23eb20b9eed21cb0101221015111fa226539ee", .table = "bb06f97ebcd70eec2d8a8cdbc78def15300ee2ef902a5259821fb682fcac7b0a" },
            .{ .focus = 0x6, .view_box = 9, .gamma = 2, .running = true, .pixels = "d3cf72cd09d3b015a5a172e12ec6080e426fe265b891ffeb06f10d3f6771d7e3", .palette = "dc5b7a775aff01b11536864309d585c803a80c8e9019a076e60a4a2ad9e30448", .table = "bb06f97ebcd70eec2d8a8cdbc78def15300ee2ef902a5259821fb682fcac7b0a" },
            .{ .focus = 0x3e8, .view_box = 9, .gamma = 2, .running = true, .pixels = "e9a8822f23e37bfb7b6293334fbc075d3a58a78127c9d091f0be77b7f30acd93", .palette = "e6f30796b42f1d39c4d6413feea2abf58e8acbba2179c76e1b80ac1ce83dec84", .table = "bb06f97ebcd70eec2d8a8cdbc78def15300ee2ef902a5259821fb682fcac7b0a" },
            .{ .focus = 0x3e8, .view_box = 9, .gamma = 2, .running = true, .pixels = "e9a8822f23e37bfb7b6293334fbc075d3a58a78127c9d091f0be77b7f30acd93", .palette = "dfc65576995a7441d8b84d3c6aafb9b06a4e668afc9dc0b72fd64a5cd78da8ab", .table = "bb06f97ebcd70eec2d8a8cdbc78def15300ee2ef902a5259821fb682fcac7b0a" },
            .{ .focus = 0x3e8, .view_box = 9, .gamma = 2, .running = false, .pixels = "90f6820ed1bf24965ed28fc560d4e8ad8aa2d52d7c6323cf7fb9e18463d50cf9", .palette = "92934585759d6c22719ae725765a55eafdcb8e898e8ce8b1d59f0801c8dde881", .table = "bb06f97ebcd70eec2d8a8cdbc78def15300ee2ef902a5259821fb682fcac7b0a" },
        },
        .sounds = &.{ -1, 0, 1, 2, 3 },
        .writes = 3,
        .registry = &.{ .{ "View Box", "9" }, .{ "Gamma", "2" } },
        .views = 1,
        .view = .{ 20, 15, 600, 410 },
        .exit = -1,
    },
};

const Event = struct { key: u8 = 0, shift: bool = false, mouse: ?[3]i32 = null, now: u32 = 0 };

const Frame = struct {
    focus: ?u32,
    view_box: i32,
    gamma: i32,
    running: bool,
    pixels: []const u8,
    palette: []const u8,
    table: []const u8,
};

const Case = struct {
    name: []const u8,
    view_box: i32 = 14,
    gamma: i32 = 0,
    events: []const Event,
    frames: []const Frame,
    sounds: []const i32,
    writes: u32,
    registry: []const [2][]const u8,
    views: u32,
    view: ?[4]i32 = null,
    exit: ?i32 = null,
};

fn hashEquals(bytes: []const u8, expected: []const u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    try std.testing.expectEqualStrings(expected, &std.fmt.bytesToHex(hash, .lower));
}

test "OPTIONS frames, focus, settings and sounds match the reference" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    const menu = try pcx.decode(a, try archive.find("NMM.PCX", 0x50424d50));
    defer menu.deinit(a);
    const pixels = try a.dupe(u8, menu.pixels);
    defer a.free(pixels);
    const drivers = [_][]const u8{ "Joystick", "Mouse", "Keyboard" };

    for (cases) |case| {
        errdefer std.debug.print("case {s}\n", .{case.name});
        var store = settings.Store.init(a);
        defer store.deinit();
        var display = display_palette.Display{ .brightness = 255, .gamma = case.gamma };
        var view = view_box.State{ .index = case.view_box };
        var shared = dialog.Shared{};
        var palette = menu.palette;
        _ = display.setBrightness(0xff);
        var main = try options.Main.init(archive, .{ .settings = &store, .display = &display, .view_box = &view, .drivers = &drivers }, &fonts);
        var screen: dialog.Dialog = undefined;
        try screen.open(a, archive, &shared, null, main.page(), &options.records, &fonts, &cursor, options.background, null, &palette, .{});
        errdefer _ = screen.close() catch {};
        var sounds: std.ArrayList(i32) = .empty;
        defer sounds.deinit(a);
        for (0..shared.sounds) |_| try sounds.append(a, -1);
        var mouse: [3]i32 = .{ 0, 0, 0 };
        for (case.events, case.frames, 0..) |event, expected, i| {
            errdefer std.debug.print("frame {d}\n", .{i});
            if (event.key != 0) screen.keys.push(event.key);
            if (event.mouse) |m| mouse = m;
            const before = shared.sounds;
            try screen.frame(.{ .x = mouse[0], .y = mouse[1], .buttons = @intCast(mouse[2]), .shift = event.shift }, event.now, &palette);
            _ = try screen.render(pixels, &palette);
            screen.reload();
            for (before..shared.sounds) |_| try sounds.append(a, @intCast(i));
            try std.testing.expectEqual(expected.focus, if (shared.focus) |focus| focus.id else null);
            try std.testing.expectEqual(expected.view_box, view.index);
            try std.testing.expectEqual(expected.gamma, display.gamma);
            try std.testing.expectEqual(expected.running, screen.running);
            try hashEquals(&display.table, expected.table);
            try hashEquals(std.mem.asBytes(&palette), expected.palette);
            try hashEquals(pixels, expected.pixels);
        }
        if (case.exit) |result| try std.testing.expectEqual(result, try screen.close()) else _ = try screen.close();
        try std.testing.expectEqualSlices(i32, case.sounds, sounds.items);
        try std.testing.expectEqual(@as(?*dialog.Widget, null), shared.focus);
        for (case.registry) |entry| try std.testing.expectEqualStrings(entry[1], (try store.read(null, null, entry[0])).?);
        try std.testing.expectEqual(case.views, view.applied);
        if (case.view) |rect| try std.testing.expectEqual(view_box.Rect{ .x = rect[0], .y = rect[1], .width = rect[2], .height = rect[3] }, view.rect);
        _ = case.writes;
    }
}

const FailingPage = struct {
    fail_on: dialog.Message,

    fn page(self: *FailingPage) dialog.Page {
        return .{ .context = self, .call = call };
    }

    fn call(context: *anyopaque, _: *dialog.Dialog, message: dialog.Message, _: u32, value: i32) anyerror!void {
        const self: *FailingPage = @ptrCast(@alignCast(context));
        if (message == self.fail_on and (message != .focus or value == 1)) return error.PageFailed;
    }
};

test "a dialog that fails to open or close still frees its widgets and restores shared focus" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "inputs/OUTLAWS_CD1/OUTLAWS/OUTLAWS.LAB", a, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const archive = try lab.Archive.init(bytes);
    const fonts = try dialog.Fonts.load(archive);
    var cursor = try nwx.Costume.parse(a, try archive.find("CURSOR.NWX", 0x57415846));
    defer cursor.deinit();
    var palette: [256]u32 = @splat(0);
    const records = [_]dialog.Record{.{ .kind = .button, .id = 7, .rect = .{ .top = 0, .left = 0, .height = 10, .width = 10 } }};
    var shared = dialog.Shared{};

    var parent: dialog.Dialog = undefined;
    var quiet = FailingPage{ .fail_on = .step };
    try parent.open(a, archive, &shared, null, quiet.page(), &records, &fonts, &cursor, null, null, &palette, .{});
    parent.background_loaded = true;
    const parent_focus = shared.focus;
    try std.testing.expect(parent_focus != null);

    var child: dialog.Dialog = undefined;
    var focus_fails = FailingPage{ .fail_on = .focus };
    try std.testing.expectError(error.PageFailed, child.open(a, archive, &shared, &parent, focus_fails.page(), &records, &fonts, &cursor, null, null, &palette, .{}));
    try std.testing.expectEqual(parent_focus, shared.focus);
    try std.testing.expectEqual(@as(i32, 0), shared.depth);
    try std.testing.expect(parent.background_loaded);

    var close_fails = FailingPage{ .fail_on = .close };
    try child.open(a, archive, &shared, &parent, close_fails.page(), &records, &fonts, &cursor, null, null, &palette, .{});
    try std.testing.expectError(error.PageFailed, child.close());
    try std.testing.expectEqual(parent_focus, shared.focus);
    try std.testing.expectEqual(@as(i32, 0), shared.depth);
    _ = try parent.close();
}
