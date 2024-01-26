const std = @import("std");
const position = @import("position.zig");
const ms = @import("movescorer.zig");
const tt = @import("tt.zig");
const history = @import("history.zig");
const evaluation = @import("evaluation.zig");

const Instant = std.time.Instant;

const Position = position.Position;
const Piece = position.Piece;
const Color = position.Color;
const Move = position.Move;

const DefaultPrng = std.rand.DefaultPrng;
const Random = std.rand.Random;

pub const MAX_DEPTH = 100;
pub const MAX_PLY = 128;
pub const MAX_MOVES = 256;
pub const MAX_MATE_PLY = 50;
pub const MAX_SCORE = 50_000;
pub const MATE_VALUE = 49_000;
pub const MATED_IN_MAX = MAX_PLY - MATE_VALUE;

const histroy_depth = [_]i32{ 3, 2 };
const history_limit = [_]i32{ -1000, -2000 };
const futility_histroy_limit = [_]i32{ -500, -1000 };
const lmp_depth = 8;

var lmp = [2][11]i8{
    [_]i8{ 0, 2, 3, 5, 9, 13, 18, 25, 34, 45, 55 },
    [_]i8{ 0, 5, 6, 9, 14, 21, 30, 41, 55, 69, 84 },
};
var lmr: [MAX_DEPTH][MAX_MOVES]i8 = undefined;

inline fn depth_as_i32(depth: i8) i32 {
    return @as(i32, @intCast(depth));
}

pub inline fn _is_mate_score(score: i32) bool {
    return ((score <= -MATE_VALUE + MAX_MATE_PLY) or (score >= MATE_VALUE - MAX_MATE_PLY));
}

pub inline fn _mate_in(score: i32) i32 {
    return if (score > 0) @divFloor(MATE_VALUE - score + 1, 2) else @divFloor(-MATE_VALUE - score, 2);
}

pub inline fn init_lmr() void {
    for (0..MAX_DEPTH) |depth| {
        for (0..MAX_MOVES) |played| {
            lmr[depth][played] = @intFromFloat(1.0 + @log(@as(f32, @floatFromInt(depth))) * @log(@as(f32, @floatFromInt(played))) * 0.5);
        }
    }
}

pub fn start_search(search: *Search, pos: *Position) void {
    if (pos.side_to_play == Color.White) {
        search.iterative_deepening(pos, Color.White);
    } else {
        search.iterative_deepening(pos, Color.Black);
    }
}

pub const Termination = enum(u3) { INFINITE, DEPTH, NODES, TIME, MOVETIME };

pub const SearchManager = struct {
    termination: Termination = Termination.INFINITE,
    max_ms: u64 = 1000,
    early_ms: u64 = 1000,
    max_nodes: ?u32 = null,

    pub fn new() SearchManager {
        return SearchManager{
            .termination = Termination.INFINITE,
            .max_ms = 1000,
            .early_ms = 1000,
            .max_nodes = null,
        };
    }

    pub fn set_time_limits(self: *SearchManager, movestogo: ?u32, movetime: ?u64, rem_time: ?u64, time_inc: ?u32) void {
        const overhead: u6 = 50;

        if (self.termination == Termination.INFINITE or self.termination == Termination.DEPTH or self.termination == Termination.NODES) {
            self.max_ms = 1 << 63;
            self.early_ms = self.max_ms;
        } else if (self.termination == Termination.TIME or self.termination == Termination.MOVETIME) {
            if (movetime != null) {
                self.max_ms = movetime.? - overhead;
                self.early_ms = self.max_ms;
                return;
            } else if (rem_time != null) {
                var inc: u32 = if (time_inc != null) time_inc.? else 0;
                if (rem_time.? <= overhead) {
                    self.max_ms = @max(10, overhead - 10);
                    self.early_ms = self.max_ms;
                    return;
                }
                if (movestogo == null) {
                    self.max_ms = inc + (rem_time.? - overhead) / 20;
                    self.early_ms = 3 * self.max_ms / 4;
                } else {
                    self.max_ms = inc + ((2 * (rem_time.? - overhead)) / (2 * movestogo.? + 1));
                    self.early_ms = self.max_ms;
                }
                self.max_ms = @min(self.max_ms, rem_time.? - overhead);
                self.early_ms = @min(self.early_ms, rem_time.? - overhead);
                return;
            } else {
                self.max_ms = 1 << 63;
                self.early_ms = self.max_ms;
                return;
            }
        } else {
            unreachable;
        }
    }
};

pub const NodeState = struct {
    eval: i32 = undefined,
    is_null: bool = false,
    is_tactical: bool = false,
    move: Move = Move.empty(),
    piece: Piece = Piece.NO_PIECE,
    dextension: i8 = 0,
};

pub const Search = struct {
    best_move: Move = undefined,
    stop_on_time: bool = false,
    stop: bool = false,
    timer: std.time.Timer = undefined,
    max_depth: u32 = MAX_DEPTH - 1,
    nodes: u64 = 0,
    ply: u16 = 0,
    seldepth: u16 = 0,

    pv_length: [MAX_PLY]u16 = undefined,
    pv_table: [MAX_PLY][MAX_PLY]Move = undefined,

    mv_killer: [MAX_PLY + 1][2]Move = undefined,
    mv_counter: [position.NPIECES][64]Move = undefined,
    sc_history: [2][64][64]i32 = undefined,

    ns_stack: [MAX_PLY + 4]NodeState = undefined,

    manager: SearchManager = undefined,

    pub fn new() Search {
        var searcher = Search{};

        searcher.clear_for_new_game();
        return searcher;
    }

    inline fn clear_pv_table(self: *Search) void {
        for (0..MAX_PLY) |i| {
            for (0..MAX_PLY) |j| {
                self.pv_table[i][j] = Move.empty();
            }
            self.pv_length[i] = 0;
        }
    }

    inline fn clear_mv_killer(self: *Search) void {
        for (0..(MAX_PLY + 1)) |i| {
            self.mv_killer[i][0] = Move.empty();
            self.mv_killer[i][1] = Move.empty();
        }
    }

    inline fn clear_mv_counter(self: *Search) void {
        for (0..position.NPIECES) |pc| {
            for (0..64) |sq| {
                self.mv_counter[pc][sq] = Move.empty();
            }
        }
    }

    inline fn clear_sc_history(self: *Search) void {
        for (0..2) |pc| {
            for (0..64) |sq1| {
                for (0..64) |sq2| {
                    self.sc_history[pc][sq1][sq2] = 0;
                }
            }
        }
    }

    inline fn age_sc_history(self: *Search) void {
        for (0..2) |pc| {
            for (0..64) |sq1| {
                for (0..64) |sq2| {
                    self.sc_history[pc][sq1][sq2] = @divTrunc(self.sc_history[pc][sq1][sq2], 2);
                }
            }
        }
    }

    inline fn clear_node_state_stack(self: *Search) void {
        for (0..(MAX_PLY + 4)) |i| {
            self.ns_stack[i].eval = 0;
            self.ns_stack[i].is_null = false;
            self.ns_stack[i].is_tactical = false;
            self.ns_stack[i].move = Move.empty();
            self.ns_stack[i].piece = Piece.NO_PIECE;
            self.ns_stack[i].dextension = 0;
        }
    }

    pub fn clear_for_new_game(self: *Search) void {
        self.clear_pv_table();
        self.clear_mv_killer();
        self.clear_mv_counter();
        self.clear_sc_history();
        self.clear_node_state_stack();

        self.best_move = Move.empty();
        self.stop_on_time = false;
        self.stop = false;

        self.nodes = 0;
        self.ply = 0;
    }

    pub fn clear_for_new_search(self: *Search) void {
        self.clear_pv_table();
        self.clear_mv_killer();
        self.clear_mv_counter();
        self.clear_sc_history();
        self.clear_node_state_stack();

        self.best_move = Move.empty();
        self.stop_on_time = false;
        self.stop = false;

        self.nodes = 0;
        self.ply = 0;
    }

    pub inline fn check_stop_conditions(self: *Search) bool {
        if (self.stop) return true;

        if (self.manager.termination == Termination.NODES and self.nodes >= self.manager.max_nodes.?) {
            self.stop = true;
            return true;
        }

        if (self.nodes & 1024 == 0 and ((self.timer.read() / std.time.ns_per_ms) >= self.manager.max_ms)) {
            self.stop = true;
            self.stop_on_time = true;
            return true;
        }

        return false;
    }

    pub inline fn check_early_stop_conditions(self: *Search, pos: *Position) bool {
        if (self.stop) return true;

        var early_adjusted_ms = self.manager.early_ms;

        if (self.manager.termination == Termination.TIME) {
            var factor: f32 = 1.0;
            if ((pos.eval.phase[0] + pos.eval.phase[1]) == 64) {
                factor *= 0.8;
            }
            early_adjusted_ms = @as(u64, @intFromFloat(@as(f32, @floatFromInt(early_adjusted_ms)) * factor));
        }
        if ((self.timer.read() / std.time.ns_per_ms) >= early_adjusted_ms) {
            return true;
        }

        return false;
    }

    pub fn iterative_deepening(self: *Search, pos: *Position, comptime color: Color) void {
        const stdout = std.io.getStdOut().writer();
        const allocator = std.heap.c_allocator;

        self.clear_for_new_search();

        var alpha: i32 = -MAX_SCORE;
        var beta: i32 = MAX_SCORE;
        var score: i32 = 0;
        var delta: i32 = 25;

        var it_depth: i8 = 1;
        var depth = it_depth;

        self.timer = std.time.Timer.start() catch unreachable;

        mainloop: while (it_depth <= self.max_depth) {
            self.ply = 0;
            self.seldepth = 0;
            self.nodes = 0;
            depth = it_depth;

            if (depth >= 7) {
                delta = 25;
            } else {
                delta = MAX_SCORE;
            }

            alpha = @max(-MAX_SCORE, score - delta);
            beta = @min(score + delta, MAX_SCORE);

            const start = Instant.now() catch unreachable;

            aspirationloop: while (delta <= MAX_SCORE) {
                score = self.pvs(@max(1, depth), alpha, beta, pos, false, color);

                if (self.stop) {
                    break :mainloop;
                }

                self.best_move = self.pv_table[0][0];

                if (score <= alpha) {
                    beta = @divTrunc(alpha + beta, 2);
                    alpha = @max(-MAX_SCORE, alpha - delta);
                    //depth = @as(i8, @intCast(self.max_depth));
                } else if (score >= beta) {
                    beta = @min(beta + delta, MAX_SCORE);
                    depth -= 1;
                } else {
                    break :aspirationloop;
                }

                delta *= 2;
            }

            if (self.stop) {
                break :mainloop;
            }

            const now = Instant.now() catch unreachable;
            const time_elapsed = now.since(start);
            const elapsed_nanos = @as(f64, @floatFromInt(time_elapsed));
            const elapsed_seconds = elapsed_nanos / 1_000_000_000;
            const elapsed_ms: u32 = @intFromFloat(elapsed_nanos / 1_000_000);
            const nps: u46 = @intFromFloat(@as(f64, @floatFromInt(self.nodes)) / elapsed_seconds);

            //self.best_move = self.pv_table[0][0];

            const est_hash_full = tt.TT.hash_full();

            _ = std.fmt.format(stdout, "info score ", .{}) catch unreachable;
            if (_is_mate_score(score)) {
                _ = std.fmt.format(stdout, "mate {} ", .{_mate_in(score)}) catch unreachable;
            } else {
                _ = std.fmt.format(stdout, "cp {} ", .{score}) catch unreachable;
            }
            _ = std.fmt.format(stdout, "depth {} seldepth {} nodes {} nps {d} time {d} hashfull {d} pv ", .{ it_depth, self.seldepth, self.nodes, nps, elapsed_ms, est_hash_full }) catch unreachable;

            for (0..self.pv_length[0]) |next_ply| {
                var pv_move_str = self.pv_table[0][next_ply].to_str(allocator);
                defer allocator.free(pv_move_str);
                _ = std.fmt.format(stdout, "{s} ", .{pv_move_str}) catch unreachable;
            }
            _ = std.fmt.format(stdout, "\n", .{}) catch unreachable;

            if (self.stop or self.check_early_stop_conditions(pos)) {
                self.stop = true;
                break :mainloop;
            }

            it_depth += 1;
        }

        // if (self.best_move.is_empty()) {
        //     var move_list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        //     defer move_list.deinit();
        //     comptime var me = if (color == Color.White) Color.White else Color.Black;
        //     pos.generate_legals(me, &move_list);
        //     var score_list = std.ArrayList(i32).initCapacity(std.heap.c_allocator, move_list.items.len) catch unreachable;
        //     defer score_list.deinit();
        //     ms.score_move(pos, self, &move_list, &score_list, Move.empty(), me);
        //     self.best_move = ms.get_next_best(&move_list, &score_list, 0);
        // }
    }

    pub fn pvs(self: *Search, _depth: i8, _alpha: i32, _beta: i32, pos: *Position, cutnode: bool, comptime color: Color) i32 {
        comptime var opp = if (color == Color.White) Color.Black else Color.White;
        comptime var me = if (color == Color.White) Color.White else Color.Black;

        var depth = _depth;
        var qsearch: bool = if (depth <= 0) true else false;
        var is_root: bool = if (self.ply == 0) true else false;
        var in_check = pos.in_check(me);
        var full_search: bool = false;

        var alpha: i32 = _alpha;
        var beta: i32 = _beta;
        var is_pv: bool = if (alpha != beta - 1) true else false;
        var r_alpha: i32 = undefined;
        var r_beta: i32 = undefined;

        var best_score: i32 = undefined;
        var score: i32 = undefined;

        var extension: i8 = 0;
        var is_null: bool = false;
        if (self.ply >= 1 and self.ns_stack[self.ply - 1].is_null) {
            is_null = true;
        }

        self.seldepth = @max(self.ply, self.seldepth);

        if (qsearch) {
            if (in_check) {
                depth = 1;
            } else {
                return self.quiescence(alpha, beta, pos, me);
            }
        }

        self.pv_length[self.ply] = 0;

        self.nodes += 1;

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        if (!is_root) {
            if (pos.is_draw()) return 1 - (@as(i32, @intCast(self.nodes & 2)));

            if (self.ply >= MAX_PLY) {
                if (in_check) return 0 else return pos.eval.eval(pos, me);
            }

            r_alpha = @max(alpha, -MATE_VALUE + @as(i32, self.ply));
            r_beta = @min(beta, MATE_VALUE - @as(i32, self.ply) + 1);

            if (r_alpha >= r_beta) return r_alpha;
        }

        var tt_move = Move.empty();
        var tt_score: i32 = -MATE_VALUE;
        var tt_bound = tt.Bound.BOUND_NONE;
        var tt_depth: u8 = 0;

        var entry = tt.TT.fetch(pos.hash);
        //var tt_hit: bool = if (entry != null) true else false;
        //var tt_hit: bool = !skip_move and !is_null and (entry != null);
        var tt_hit: bool = entry != null;

        if (tt_hit) {
            tt_move = entry.?.move;
            tt_bound = entry.?.bound;
            tt_score = tt.TT.adjust_hash_score(entry.?.score, self.ply);
            tt_depth = entry.?.depth;

            if ((!is_pv or depth == 0) and tt_depth >= depth and (cutnode or tt_score <= alpha)) {
                if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                    (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
                    (tt_bound == tt.Bound.BOUND_EXACT))
                {
                    if (tt_score >= beta and tt_move.is_quiet()) {
                        const depth_i32: i32 = @as(i32, @intCast(tt_depth));
                        const bonus: i32 = @min(16 * depth_i32 * depth_i32, history.max_histroy);
                        self.sc_history[color.toU4()][tt_move.from][tt_move.to] = history.histoy_bonus(self.sc_history[color.toU4()][tt_move.from][tt_move.to], bonus);
                    }

                    return tt_score;
                }
            }

            if (!is_pv and (tt_depth >= depth - 1) and (tt_bound == tt.Bound.BOUND_UPPER) and (tt_score + 140 <= alpha) and (cutnode or tt_score <= alpha)) {
                return alpha;
            }
        }

        if (depth >= 4 and tt_bound == tt.Bound.BOUND_NONE and !is_root) {
            depth -= 1;
        }

        var static_eval = pos.eval.eval(pos, me);
        best_score = static_eval;

        self.ns_stack[self.ply].eval = static_eval;

        if (tt_hit and !in_check) {
            if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score > static_eval) or
                (tt_bound == tt.Bound.BOUND_UPPER and tt_score < static_eval) or
                (tt_bound == tt.Bound.BOUND_EXACT))
            {
                best_score = tt_score;
            }
        }

        var improving: u1 = if (self.ply >= 2 and static_eval > self.ns_stack[self.ply - 2].eval and !in_check) 1 else 0;
        self.ns_stack[self.ply].dextension = if (is_root) 0 else self.ns_stack[self.ply - 1].dextension;

        var prune: bool = true;
        if (prune and !in_check and !is_pv) {
            const razor_depth = 2;
            const razor_margin = 150 + @as(i32, @intCast(improving)) * 75; // + 75 * (if (depth > 2) (depth - 2) else 0);
            //if (depth <= 2 and static_eval + 150 < alpha) {
            if (depth <= razor_depth and static_eval + razor_margin <= alpha) {
                //std.debug.print("razor0 = {}", .{razor0});
                const raz_score = self.quiescence(alpha, beta, pos, me);
                if (raz_score <= alpha) {
                    return raz_score;
                }
            }

            if ((depth <= 8) and ((best_score - 85 * (@as(i32, @intCast(depth)) - improving)) >= beta)) {
                return best_score;
            }

            if (best_score >= beta and !is_null and depth >= 2 and (pos.eval.phase[me.toU4()] > 0) and (!tt_hit or !(tt_bound == tt.Bound.BOUND_UPPER) or tt_score >= beta)) {
                var R = 4 + @divTrunc(depth, 5) + @as(i8, @intCast(@min(3, @divTrunc(best_score - beta, 191))));
                R += if (self.ns_stack[self.ply - 1].is_tactical) 1 else 0;
                //R = @min(depth, R);

                // make null move
                self.ns_stack[self.ply].is_null = true;
                self.ns_stack[self.ply].is_tactical = false;
                self.ns_stack[self.ply].move = Move.empty();
                self.ns_stack[self.ply].piece = Piece.NO_PIECE;
                self.ply += 1;
                pos.play_null_move();
                tt.TT.prefetch(pos.hash);
                // make move

                score = -self.pvs(depth - R, -beta, -beta + 1, pos, !cutnode, opp);

                // unmake move
                self.ply -= 1;
                pos.undo_null_move();
                // unmake move

                if (score >= beta) {
                    return if (_is_mate_score(score)) beta else score;
                }
            }
        }

        // if (cutnode and depth >= 7 and tt_bound == tt.Bound.BOUND_NONE) {
        //     depth -= 1;
        // }

        best_score = -MATE_VALUE + @as(i32, self.ply);
        var best_move = Move.empty();

        var move_list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        defer move_list.deinit();

        pos.generate_legals(me, &move_list);

        if (move_list.items.len == 0) {
            if (in_check) {
                // Checkmate
                return -MATE_VALUE + @as(i32, self.ply);
            } else {
                // Stalemate
                return 0;
            }
        }

        var score_list = std.ArrayList(i32).initCapacity(std.heap.c_allocator, move_list.items.len) catch unreachable;
        defer score_list.deinit();
        ms.score_move(pos, self, &move_list, &score_list, tt_move, me);

        self.mv_killer[self.ply + 1][0] = Move.empty();
        self.mv_killer[self.ply + 1][1] = Move.empty();
        var quiet_list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, move_list.items.len) catch unreachable;
        defer quiet_list.deinit();
        var quet_mv_pieces = std.ArrayList(Piece).initCapacity(std.heap.c_allocator, move_list.items.len) catch unreachable;
        defer quet_mv_pieces.deinit();
        var quiets_tried: u8 = 0;
        var played: u8 = 0;
        var skip_quiets = false;

        for (0..move_list.items.len) |mv_idx| {
            var move = ms.get_next_best(&move_list, &score_list, mv_idx);

            var mv_quiet = move.is_quiet();
            var piece = pos.board[move.from];

            var sc_hist = self.sc_history[me.toU4()][move.from][move.to];

            if (!is_root and best_score > MATED_IN_MAX) {
                if (mv_quiet) {
                    if (skip_quiets) {
                        continue;
                    }

                    if (depth <= histroy_depth[improving] and sc_hist < (history_limit[improving] * depth)) {
                        continue;
                    }

                    var futilityMargin = static_eval + 90 * @as(i32, depth);
                    if (futilityMargin <= alpha and depth <= 8 and (sc_hist < futility_histroy_limit[improving])) {
                        skip_quiets = true;
                    }

                    if ((depth <= lmp_depth) and (quiets_tried >= lmp[improving][@min(11, @as(usize, @intCast(depth)))])) {
                        skip_quiets = true;
                    }
                }
            }

            if (mv_quiet) {
                quiets_tried += 1;
                quiet_list.append(move) catch unreachable;
                quet_mv_pieces.append(piece) catch unreachable;
            }

            var new_depth = depth;

            // make move
            played += 1;
            self.ns_stack[self.ply].is_null = false;
            self.ns_stack[self.ply].is_tactical = !mv_quiet;
            self.ns_stack[self.ply].move = move;
            self.ns_stack[self.ply].piece = piece;
            self.ply += 1;
            pos.play(move, me);
            tt.TT.prefetch(pos.hash);
            // make move

            if (pos.in_check(me)) {
                new_depth += 1;
            }

            if (!is_root) {
                new_depth += extension;
            }

            if (extension > 1) {
                self.ns_stack[self.ply].dextension += 1;
            }

            var reduction: i8 = 0;

            if (mv_idx > 0 and depth > 2) {
                if (mv_quiet) {
                    reduction = lmr[@as(usize, @intCast(@min(depth, MAX_DEPTH - 1)))][@as(usize, @intCast(@min(mv_idx + 1, MAX_MOVES - 1)))];

                    if (improving == 0) reduction += 1;
                    if (reduction > 0 and is_pv) reduction -= 1;

                    if (move.equal(self.mv_killer[self.ply][0]) or move.equal(self.mv_killer[self.ply][1])) {
                        reduction -= 1;
                    }

                    reduction -= @as(i8, @intCast(@max(-2, @min(2, @divTrunc(sc_hist, 7000)))));
                }

                reduction = @min(depth - 1, @max(reduction, 1));

                score = -self.pvs(new_depth - reduction, -alpha - 1, -alpha, pos, true, opp);

                full_search = (score > alpha) and (reduction != 1);
            } else {
                full_search = !is_pv or (played > 1);
            }

            if (full_search) {
                score = -self.pvs(new_depth - 1, -alpha - 1, -alpha, pos, !cutnode, opp);
            }

            if (is_pv and (played == 1 or score > alpha)) {
                score = -self.pvs(new_depth - 1, -beta, -alpha, pos, false, opp);
            }

            // unmake move
            self.ply -= 1;
            pos.undo(move, me);
            tt.TT.prefetch_write(pos.hash);
            // unmake move

            if (extension > 1) {
                self.ns_stack[self.ply].dextension -= 1;
            }

            if (self.check_stop_conditions()) {
                self.stop_on_time = true;
                return 0;
            }

            if (score > best_score) {
                best_score = score;

                if (score > alpha) {
                    best_move = move;
                    self.update_pv(move);

                    alpha = score;

                    if (alpha >= beta) {
                        if (mv_quiet) {
                            history.update_all_history(self, move, quiet_list, quet_mv_pieces, depth, me);
                        }

                        break;
                    }
                }
            }
        }

        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (alpha != _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, @as(u8, @intCast(depth)), tt.TT.age));

        return best_score;
    }

    pub fn quiescence(self: *Search, _alpha: i32, _beta: i32, pos: *Position, comptime color: Color) i32 {
        comptime var opp = if (color == Color.White) Color.Black else Color.White;
        comptime var me = if (color == Color.White) Color.White else Color.Black;
        var alpha: i32 = @max(_alpha, -MATE_VALUE + @as(i32, self.ply));
        var beta: i32 = @min(_beta, MATE_VALUE - @as(i32, self.ply) + 1);
        var best_score: i32 = undefined;
        var score: i32 = undefined;
        var in_check = pos.in_check(color);

        self.pv_length[self.ply] = 0;
        self.seldepth = @max(self.ply, self.seldepth);

        if (alpha >= beta) return alpha;

        if (self.ply >= MAX_PLY) return pos.eval.eval(pos, me);

        if (self.check_stop_conditions()) {
            self.stop_on_time = true;
            return 0;
        }

        if (pos.is_draw()) return 1 - (@as(i32, @intCast(self.nodes & 2)));

        var entry = tt.TT.fetch(pos.hash);
        var tt_hit: bool = if (entry != null) true else false;

        var tt_move = Move.empty();
        var tt_score: i32 = 0;
        var tt_bound = tt.Bound.BOUND_NONE;
        var tt_depth: u8 = 0;

        if (tt_hit) {
            tt_move = entry.?.move;
            tt_bound = entry.?.bound;
            tt_score = tt.TT.adjust_hash_score(entry.?.score, self.ply);
            tt_depth = entry.?.depth;

            //if (!is_pv and tt_depth > depth) {
            if ((tt_bound == tt.Bound.BOUND_LOWER and tt_score >= beta) or
                (tt_bound == tt.Bound.BOUND_UPPER and tt_score <= alpha) or
                (tt_bound == tt.Bound.BOUND_EXACT))
            {
                return tt_score;
            }
            //}
        }

        if (in_check) {
            best_score = -MATE_VALUE + @as(i32, self.ply);
        } else {
            best_score = pos.eval.eval(pos, me);

            if (best_score >= beta) {
                return best_score;
            }

            if (best_score > alpha) {
                alpha = best_score;
            }
        }

        var best_move = Move.empty();

        var move_list = std.ArrayList(Move).initCapacity(std.heap.c_allocator, 48) catch unreachable;
        defer move_list.deinit();
        pos.generate_captures(me, &move_list);

        var score_list = std.ArrayList(i32).initCapacity(std.heap.c_allocator, move_list.items.len) catch unreachable;
        defer score_list.deinit();
        ms.score_move(pos, self, &move_list, &score_list, tt_move, me);

        for (0..move_list.items.len) |mv_idx| {
            var move = ms.get_next_best(&move_list, &score_list, mv_idx);

            if (!ms.see(pos, move, 1)) {
                continue;
            }

            // make move
            self.ply += 1;
            pos.play(move, me);
            tt.TT.prefetch(pos.hash);
            // make move

            self.nodes += 1;

            score = -self.quiescence(-beta, -alpha, pos, opp);

            // unmake move
            self.ply -= 1;
            pos.undo(move, me);
            tt.TT.prefetch_write(pos.hash);
            // unmake move

            if (score > best_score) {
                best_score = score;
                if (score > alpha) {
                    best_move = move;
                    self.update_pv(move);
                    alpha = score;

                    if (alpha >= beta) {
                        break;
                    }
                }
            }
        }

        tt_bound = if (best_score >= beta) tt.Bound.BOUND_LOWER else if (best_score > _alpha) tt.Bound.BOUND_EXACT else tt.Bound.BOUND_UPPER;
        tt.TT.store(tt.scoreEntry.new(pos.hash, best_move, tt.TT.to_hash_score(best_score, self.ply), tt_bound, 0, tt.TT.age));
        return best_score;
    }

    inline fn update_pv(self: *Search, move: Move) void {
        self.pv_table[self.ply][0] = move;
        std.mem.copy(Move, self.pv_table[self.ply][1..(self.pv_length[self.ply + 1] + 1)], self.pv_table[self.ply + 1][0..(self.pv_length[self.ply + 1])]);
        self.pv_length[self.ply] = self.pv_length[self.ply + 1] + 1;
    }
};
