from dataclasses import dataclass


BUS_W = 128
FP8_PER_BEAT = BUS_W // 8
I32_PER_BEAT = BUS_W // 32

ST_IDLE = 0
ST_LOAD_Q_CMD = 1
ST_LOAD_Q_DATA = 2
ST_INIT_CTX = 3
ST_LOAD_K_CMD = 4
ST_LOAD_K_DATA = 5
ST_LOAD_V_CMD = 6
ST_LOAD_V_DATA = 7
ST_COMPUTE = 8
ST_NEXT_K = 9
ST_NORMALIZE = 10
ST_WRITE_O_CMD = 11
ST_WRITE_O_DATA = 12
ST_NEXT_Q = 13
ST_DONE = 14


@dataclass
class Cfg:
    seq_len: int
    head_dim: int
    score_scale_q1_14: int
    round_mode: int
    saturate_en: int
    tq: int = 32
    tk: int = 64
    norm_round: int = 0


def s32(v: int) -> int:
    v &= 0xFFFFFFFF
    return v if v < 0x80000000 else v - 0x100000000


def fp8_e4m3_to_q4_11(x: int) -> int:
    sign = (x >> 7) & 1
    exp = (x >> 3) & 0xF
    frac = x & 0x7
    if exp == 0:
        mag = frac << 2
    elif exp == 0xF:
        mag = 32767
    else:
        mag = (8 + frac) << (exp + 1)
        mag = min(mag, 32767)
    return -mag if sign else mag


def round_shift_right_64(v: int, sh: int, mode: int) -> int:
    if sh <= 0:
        return v
    t = v
    if mode == 1:
        if v >= 0:
            t = v + (1 << (sh - 1))
        else:
            t = v - (1 << (sh - 1))
    return t >> sh


def exp2_approx_q0_15(delta_q8_11: int) -> int:
    dlt = delta_q8_11 >> 8
    if dlt >= 0:
        return 32767
    if dlt <= -15:
        return 0
    return 32767 >> (-dlt)


def ceil_div_u16(n: int, d0: int) -> int:
    return (n + d0 - 1) // d0


class Fp8DmaCycleModel:
    def __init__(self, cfg: Cfg, q, k, v):
        self.cfg = cfg
        self.q = q
        self.k = k
        self.v = v

        self.st = ST_IDLE
        self.qt = 0
        self.kt = 0
        self.rd_beat_idx = 0
        self.wr_beat_idx = 0
        self.q_beats = 0
        self.k_beats = 0
        self.v_beats = 0
        self.o_beats = 0

        self.cycle = 0
        self.perf_rd_cmd = 0
        self.perf_rd_beat = 0
        self.perf_wr_cmd = 0
        self.perf_wr_beat = 0
        self.perf_compute_cycles = 0
        self.perf_softmax_updates = 0

        self.rd_cmd_valid = 0
        self.wr_cmd_valid = 0
        self.wr_data_valid = 0
        self.rd_data_bubble = 0
        self.wr_data_bubble = 0

        self.o_busy = 0
        self.o_done = 0

        self.q_tile = [[0 for _ in range(64)] for _ in range(cfg.tq)]
        self.k_tile = [[0 for _ in range(64)] for _ in range(cfg.tk)]
        self.v_tile = [[0 for _ in range(64)] for _ in range(cfg.tk)]

        self.row_m = [-(1 << 31) for _ in range(cfg.tq)]
        self.row_l = [0 for _ in range(cfg.tq)]
        self.row_acc = [[0 for _ in range(64)] for _ in range(cfg.tq)]
        self.o_tile = [[0 for _ in range(64)] for _ in range(cfg.tq)]
        self.out = [[0 for _ in range(64)] for _ in range(cfg.seq_len)]
        self.q_sum = 0
        self.k_sum = 0
        self.v_sum = 0

    def _load_q_beat(self, beat_idx: int):
        flat_base = beat_idx * FP8_PER_BEAT
        hd = self.cfg.head_dim
        base_row = self.qt * self.cfg.tq
        for e in range(FP8_PER_BEAT):
            rr = (flat_base + e) // hd
            cc = (flat_base + e) % hd
            if rr < self.cfg.tq and cc < hd:
                self.q_tile[rr][cc] = self.q[base_row + rr][cc]
                self.q_sum += self.q[base_row + rr][cc]

    def _load_kv_beat(self, beat_idx: int, tile):
        flat_base = beat_idx * FP8_PER_BEAT
        hd = self.cfg.head_dim
        base_row = self.kt * self.cfg.tk
        src = self.k if tile == "k" else self.v
        for e in range(FP8_PER_BEAT):
            rr = (flat_base + e) // hd
            cc = (flat_base + e) % hd
            if rr < self.cfg.tk and cc < hd:
                src_row = base_row + rr
                tile_arr = self.k_tile if tile == "k" else self.v_tile
                tile_arr[rr][cc] = src[src_row][cc]
                if tile == "k":
                    self.k_sum += src[src_row][cc]
                else:
                    self.v_sum += src[src_row][cc]

    def _compute(self):
        hd = self.cfg.head_dim
        for qi in range(self.cfg.tq):
            m_loc = self.row_m[qi]
            l_loc = self.row_l[qi]
            acc = [self.row_acc[qi][d] for d in range(hd)]

            for kj in range(self.cfg.tk):
                dot_tmp = 0
                for d in range(hd):
                    qv = fp8_e4m3_to_q4_11(self.q_tile[qi][d])
                    kv = fp8_e4m3_to_q4_11(self.k_tile[kj][d])
                    dot_tmp += qv * kv

                score_tmp = round_shift_right_64(dot_tmp, 11, self.cfg.round_mode)
                score_tmp = (score_tmp * self.cfg.score_scale_q1_14) >> 14
                if self.cfg.saturate_en:
                    if score_tmp > 2147483647:
                        score_i = 2147483647
                    elif score_tmp < -2147483648:
                        score_i = -2147483648
                    else:
                        score_i = int(score_tmp)
                else:
                    score_i = s32(int(score_tmp))

                m_new = score_i if score_i > m_loc else m_loc
                exp_old = 0 if l_loc == 0 else exp2_approx_q0_15(m_loc - m_new)
                exp_new = exp2_approx_q0_15(score_i - m_new)

                l_scaled = (l_loc * exp_old) >> 15
                l_new = l_scaled + (exp_new << 1)
                m_loc = m_new
                l_loc = l_new
                self.perf_softmax_updates += 1

                for d in range(hd):
                    acc_scaled = (acc[d] * exp_old) >> 15
                    vv = fp8_e4m3_to_q4_11(self.v_tile[kj][d])
                    v_term = vv * exp_new
                    acc[d] = acc_scaled + v_term

            self.row_m[qi] = m_loc
            self.row_l[qi] = l_loc
            for d in range(hd):
                self.row_acc[qi][d] = acc[d]

    def _normalize(self):
        hd = self.cfg.head_dim
        for qi in range(self.cfg.tq):
            den = self.row_l[qi]
            for d in range(hd):
                num = self.row_acc[qi][d]
                if den == 0:
                    self.o_tile[qi][d] = 0
                elif self.cfg.norm_round:
                    adj = den >> 1
                    if num < 0:
                        adj = -adj
                    self.o_tile[qi][d] = int((num + adj) / den)
                else:
                    self.o_tile[qi][d] = int(num / den)

    def step(
        self,
        i_start: int,
        rd_cmd_hs: int = 0,
        rd_data_hs: int = 0,
        wr_cmd_hs: int = 0,
        wr_data_hs: int = 0,
    ):
        self.o_done = 0
        if self.st != ST_IDLE:
            self.cycle += 1

        if self.st == ST_IDLE:
            self.o_busy = 0
            self.rd_cmd_valid = 0
            self.wr_cmd_valid = 0
            self.wr_data_valid = 0
            if i_start:
                self.o_busy = 1
                self.qt = 0
                self.kt = 0
                self.q_beats = ceil_div_u16(self.cfg.tq * self.cfg.head_dim, FP8_PER_BEAT)
                self.k_beats = ceil_div_u16(self.cfg.tk * self.cfg.head_dim, FP8_PER_BEAT)
                self.v_beats = ceil_div_u16(self.cfg.tk * self.cfg.head_dim, FP8_PER_BEAT)
                self.o_beats = ceil_div_u16(self.cfg.tq * self.cfg.head_dim, I32_PER_BEAT)
                self.perf_rd_cmd = 0
                self.perf_rd_beat = 0
                self.perf_wr_cmd = 0
                self.perf_wr_beat = 0
                self.perf_compute_cycles = 0
                self.perf_softmax_updates = 0
                self.st = ST_LOAD_Q_CMD

        elif self.st == ST_LOAD_Q_CMD:
            self.q_sum = 0
            if rd_cmd_hs:
                self.rd_cmd_valid = 0
                self.perf_rd_cmd += 1
                self.rd_beat_idx = 0
                self.st = ST_LOAD_Q_DATA
            else:
                self.rd_cmd_valid = 1

        elif self.st == ST_LOAD_Q_DATA:
            if rd_data_hs:
                self._load_q_beat(self.rd_beat_idx)
                self.rd_beat_idx += 1
                self.perf_rd_beat += 1
                if self.rd_beat_idx >= self.q_beats:
                    self.st = ST_INIT_CTX

        elif self.st == ST_INIT_CTX:
            hd = self.cfg.head_dim
            for qi in range(self.cfg.tq):
                self.row_m[qi] = -(1 << 31)
                self.row_l[qi] = 0
                for d in range(hd):
                    self.row_acc[qi][d] = 0
                    self.o_tile[qi][d] = 0
            self.kt = 0
            self.st = ST_LOAD_K_CMD

        elif self.st == ST_LOAD_K_CMD:
            self.k_sum = 0
            if rd_cmd_hs:
                self.rd_cmd_valid = 0
                self.perf_rd_cmd += 1
                self.rd_beat_idx = 0
                self.st = ST_LOAD_K_DATA
            else:
                self.rd_cmd_valid = 1

        elif self.st == ST_LOAD_K_DATA:
            if rd_data_hs:
                self._load_kv_beat(self.rd_beat_idx, "k")
                self.rd_beat_idx += 1
                self.perf_rd_beat += 1
                if self.rd_beat_idx >= self.k_beats:
                    self.st = ST_LOAD_V_CMD

        elif self.st == ST_LOAD_V_CMD:
            self.v_sum = 0
            if rd_cmd_hs:
                self.rd_cmd_valid = 0
                self.perf_rd_cmd += 1
                self.rd_beat_idx = 0
                self.st = ST_LOAD_V_DATA
            else:
                self.rd_cmd_valid = 1

        elif self.st == ST_LOAD_V_DATA:
            if rd_data_hs:
                self._load_kv_beat(self.rd_beat_idx, "v")
                self.rd_beat_idx += 1
                self.perf_rd_beat += 1
                if self.rd_beat_idx >= self.v_beats:
                    self.st = ST_COMPUTE

        elif self.st == ST_COMPUTE:
            self.perf_compute_cycles += 1
            self._compute()
            self.st = ST_NEXT_K

        elif self.st == ST_NEXT_K:
            if self.kt + 1 >= (self.cfg.seq_len // self.cfg.tk):
                self.st = ST_NORMALIZE
            else:
                self.kt += 1
                self.st = ST_LOAD_K_CMD

        elif self.st == ST_NORMALIZE:
            self._normalize()
            self.st = ST_WRITE_O_CMD

        elif self.st == ST_WRITE_O_CMD:
            base_row = self.qt * self.cfg.tq
            for rr in range(self.cfg.tq):
                for cc in range(self.cfg.head_dim):
                    self.out[base_row + rr][cc] = self.o_tile[rr][cc]
            if wr_cmd_hs:
                self.wr_cmd_valid = 0
                self.perf_wr_cmd += 1
                self.wr_beat_idx = 0
                self.st = ST_WRITE_O_DATA
            else:
                self.wr_cmd_valid = 1

        elif self.st == ST_WRITE_O_DATA:
            if wr_data_hs:
                self.wr_data_valid = 1
                self.perf_wr_beat += 1
                if self.wr_beat_idx + 1 >= self.o_beats:
                    self.wr_data_valid = 0
                    self.st = ST_NEXT_Q
                else:
                    self.wr_beat_idx += 1

        elif self.st == ST_NEXT_Q:
            if self.qt + 1 >= (self.cfg.seq_len // self.cfg.tq):
                self.st = ST_DONE
            else:
                self.qt += 1
                self.st = ST_LOAD_Q_CMD

        elif self.st == ST_DONE:
            self.o_busy = 0
            self.o_done = 1
            if not i_start:
                self.st = ST_IDLE

    def snapshot(self):
        return {
            "state": self.st,
            "qt": self.qt,
            "kt": self.kt,
            "rd_beat_idx": self.rd_beat_idx,
            "wr_beat_idx": self.wr_beat_idx,
            "q00": self.q_tile[0][0],
            "k00": self.k_tile[0][0],
            "v00": self.v_tile[0][0],
            "q_last": self.q_tile[self.cfg.tq - 1][self.cfg.head_dim - 1],
            "k_last": self.k_tile[self.cfg.tk - 1][self.cfg.head_dim - 1],
            "v_last": self.v_tile[self.cfg.tk - 1][self.cfg.head_dim - 1],
            "q_sum": self.q_sum,
            "k_sum": self.k_sum,
            "v_sum": self.v_sum,
            "m0": self.row_m[0],
            "l0": self.row_l[0],
            "acc00": self.row_acc[0][0],
            "o00": self.o_tile[0][0],
            "perf_rd_cmd": self.perf_rd_cmd,
            "perf_rd_beat": self.perf_rd_beat,
            "perf_wr_cmd": self.perf_wr_cmd,
            "perf_wr_beat": self.perf_wr_beat,
            "perf_compute_cycles": self.perf_compute_cycles,
            "perf_softmax_updates": self.perf_softmax_updates,
            "cycle": self.cycle,
        }

    def out_matrix(self):
        return [row[: self.cfg.head_dim] for row in self.out]
