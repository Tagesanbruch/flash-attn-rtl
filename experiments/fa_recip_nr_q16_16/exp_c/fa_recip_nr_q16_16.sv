module fa_recip_nr_q16_16 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_valid,
  input  logic [31:0] i_x_q16_16,
  output logic        o_valid,
  output logic [31:0] o_recip_q16_16
);
  // Newton-Raphson reciprocal: 10-stage pipeline with pipelined 32×32 multiply
  //
  // Each 32×32 multiply is split into:
  //   Sub-stage A: four 16×16 partial products (parallel, ~1ns)
  //   Sub-stage B: accumulate partial products (~1ns)
  //
  // Pipeline:
  //   Stage 0: CLZ + normalize
  //   Stage 1: LUT lookup
  //   Stage 2: d_norm × r0 partial products   (16×16)
  //   Stage 3: accumulate dr0, extract, corr1 = 2-dr0  (add + sub)
  //   Stage 4: r0 × corr1 partial products     (16×16)
  //   Stage 5: accumulate r1_full, extract r1
  //   Stage 6: d_norm × r1 partial products   (16×16)
  //   Stage 7: accumulate dr1, extract, corr2 = 2-dr1  (add + sub)
  //   Stage 8: r1 × corr2 partial products     (16×16)
  //   Stage 9: accumulate r2_full, extract r2, de-normalize

  // ─── CLZ function ──────────────────────────────────────────────
  function automatic [5:0] clz32(input [31:0] val);
    reg [5:0] n;
    reg [31:0] x;
    begin
      if (val == 32'd0) begin
        clz32 = 6'd32;
      end else begin
        n = 6'd0;
        x = val;
        if (x[31:16] == 16'd0) begin n = n + 6'd16; x = x << 16; end
        if (x[31:24] == 8'd0)  begin n = n + 6'd8;  x = x << 8;  end
        if (x[31:28] == 4'd0)  begin n = n + 6'd4;  x = x << 4;  end
        if (x[31:30] == 2'd0)  begin n = n + 6'd2;  x = x << 2;  end
        if (x[31]    == 1'b0)  begin n = n + 6'd1;                end
        clz32 = n;
      end
    end
  endfunction

  // ═══════════════════════════════════════════════════════════════
  // Stage 0: CLZ + normalize (split from LUT for timing)
  // ═══════════════════════════════════════════════════════════════
  logic [5:0]  lz;
  logic [31:0] d_norm;

  always_comb begin
    lz     = clz32(i_x_q16_16);
    d_norm = i_x_q16_16 << lz;
  end

  logic        s0_valid;
  logic [31:0] s0_d_norm;
  logic [5:0]  s0_lz;
  logic        s0_is_zero;
  logic        s0_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_valid <= 1'b0;
    end else begin
      s0_valid   <= i_valid;
      s0_d_norm  <= d_norm;
      s0_lz      <= lz;
      s0_is_zero <= (i_x_q16_16 == 32'd0);
      s0_is_one  <= (i_x_q16_16 == 32'd1);
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 1: LUT lookup (small combinational depth)
  // ═══════════════════════════════════════════════════════════════
  logic [31:0] r0_lut;

  always_comb begin
    case (s0_d_norm[30:26])
      5'd0:  r0_lut = 32'hFC0F_C0FC;
      5'd1:  r0_lut = 32'hF489_8D60;
      5'd2:  r0_lut = 32'hED73_03B6;
      5'd3:  r0_lut = 32'hE6C2_B448;
      5'd4:  r0_lut = 32'hE070_381C;
      5'd5:  r0_lut = 32'hDA74_0DA7;
      5'd6:  r0_lut = 32'hD4C7_7B03;
      5'd7:  r0_lut = 32'hCF64_74A9;
      5'd8:  r0_lut = 32'hCA45_87E7;
      5'd9:  r0_lut = 32'hC565_C87B;
      5'd10: r0_lut = 32'hC0C0_C0C1;
      5'd11: r0_lut = 32'hBC52_640C;
      5'd12: r0_lut = 32'hB817_02E0;
      5'd13: r0_lut = 32'hB40B_40B4;
      5'd14: r0_lut = 32'hB02C_0B03;
      5'd15: r0_lut = 32'hAC76_9184;
      5'd16: r0_lut = 32'hA8E8_3F57;
      5'd17: r0_lut = 32'hA57E_B503;
      5'd18: r0_lut = 32'hA237_C32B;
      5'd19: r0_lut = 32'h9F11_65E7;
      5'd20: r0_lut = 32'h9C09_C09C;
      5'd21: r0_lut = 32'h991F_1A51;
      5'd22: r0_lut = 32'h964F_DA6C;
      5'd23: r0_lut = 32'h939A_85C4;
      5'd24: r0_lut = 32'h90FD_BC09;
      5'd25: r0_lut = 32'h8E78_356D;
      5'd26: r0_lut = 32'h8C08_C08C;
      5'd27: r0_lut = 32'h89AE_408A;
      5'd28: r0_lut = 32'h8767_AB5F;
      5'd29: r0_lut = 32'h8534_0853;
      5'd30: r0_lut = 32'h8312_6E98;
      5'd31: r0_lut = 32'h8102_0408;
    endcase
  end

  logic        s1_valid;
  logic [31:0] s1_d_norm;
  logic [31:0] s1_r0;
  logic [5:0]  s1_lz;
  logic        s1_is_zero;
  logic        s1_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else begin
      s1_valid   <= s0_valid;
      s1_d_norm  <= s0_d_norm;
      s1_r0      <= r0_lut;
      s1_lz      <= s0_lz;
      s1_is_zero <= s0_is_zero;
      s1_is_one  <= s0_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 2: d_norm × r0 — partial products (four 16×16)
  // ═══════════════════════════════════════════════════════════════
  logic [31:0] pp2_hh, pp2_hl, pp2_lh, pp2_ll;
  always_comb begin
    pp2_hh = s1_d_norm[31:16] * s1_r0[31:16];
    pp2_hl = s1_d_norm[31:16] * s1_r0[15:0];
    pp2_lh = s1_d_norm[15:0]  * s1_r0[31:16];
    pp2_ll = s1_d_norm[15:0]  * s1_r0[15:0];
  end

  logic        s2_valid;
  logic [31:0] s2_pp_hh, s2_pp_hl, s2_pp_lh, s2_pp_ll;
  logic [31:0] s2_d_norm, s2_r0;
  logic [5:0]  s2_lz;
  logic        s2_is_zero, s2_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid <= 1'b0;
    end else begin
      s2_valid   <= s1_valid;
      s2_pp_hh   <= pp2_hh;
      s2_pp_hl   <= pp2_hl;
      s2_pp_lh   <= pp2_lh;
      s2_pp_ll   <= pp2_ll;
      s2_d_norm  <= s1_d_norm;
      s2_r0      <= s1_r0;
      s2_lz      <= s1_lz;
      s2_is_zero <= s1_is_zero;
      s2_is_one  <= s1_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 3: accumulate dr0, extract dr0_q1_31, corr1 = 2 - dr0
  // ═══════════════════════════════════════════════════════════════
  logic [63:0] dr0_acc;
  logic [31:0] dr0_q1_31;
  logic [32:0] corr1;

  always_comb begin
    dr0_acc   = {s2_pp_hh, 32'b0} + {16'b0, s2_pp_hl, 16'b0}
              + {16'b0, s2_pp_lh, 16'b0} + {32'b0, s2_pp_ll};
    dr0_q1_31 = dr0_acc[63:32];
    corr1     = {1'b1, 32'h0000_0000} - {1'b0, dr0_q1_31};
  end

  logic        s3_valid;
  logic [31:0] s3_corr1;   // corr1[31:0] — Q1.31 correction
  logic        s3_corr1_ov; // corr1[32] — overflow flag
  logic [31:0] s3_d_norm, s3_r0;
  logic [5:0]  s3_lz;
  logic        s3_is_zero, s3_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_valid <= 1'b0;
    end else begin
      s3_valid    <= s2_valid;
      s3_corr1    <= corr1[31:0];
      s3_corr1_ov <= corr1[32];
      s3_d_norm   <= s2_d_norm;
      s3_r0       <= s2_r0;
      s3_lz       <= s2_lz;
      s3_is_zero  <= s2_is_zero;
      s3_is_one   <= s2_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 4: r0 × corr1 — partial products (four 16×16)
  // ═══════════════════════════════════════════════════════════════
  logic [31:0] mul4_a, mul4_b;
  logic [31:0] pp4_hh, pp4_hl, pp4_lh, pp4_ll;

  always_comb begin
    mul4_a = s3_r0;
    mul4_b = s3_corr1;
    pp4_hh = mul4_a[31:16] * mul4_b[31:16];
    pp4_hl = mul4_a[31:16] * mul4_b[15:0];
    pp4_lh = mul4_a[15:0]  * mul4_b[31:16];
    pp4_ll = mul4_a[15:0]  * mul4_b[15:0];
  end

  logic        s4_valid;
  logic [31:0] s4_pp_hh, s4_pp_hl, s4_pp_lh, s4_pp_ll;
  logic        s4_corr1_ov;
  logic [31:0] s4_r0;     // original r0 for clamp path
  logic [31:0] s4_d_norm;
  logic [5:0]  s4_lz;
  logic        s4_is_zero, s4_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s4_valid <= 1'b0;
    end else begin
      s4_valid    <= s3_valid;
      s4_pp_hh    <= pp4_hh;
      s4_pp_hl    <= pp4_hl;
      s4_pp_lh    <= pp4_lh;
      s4_pp_ll    <= pp4_ll;
      s4_corr1_ov <= s3_corr1_ov;
      s4_r0       <= s3_r0;
      s4_d_norm   <= s3_d_norm;
      s4_lz       <= s3_lz;
      s4_is_zero  <= s3_is_zero;
      s4_is_one   <= s3_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 5: accumulate r1_full, extract r1
  // ═══════════════════════════════════════════════════════════════
  logic [63:0] r1_full_acc;
  logic [31:0] r1_extracted;

  always_comb begin
    r1_full_acc = {s4_pp_hh, 32'b0} + {16'b0, s4_pp_hl, 16'b0}
               + {16'b0, s4_pp_lh, 16'b0} + {32'b0, s4_pp_ll};
    r1_extracted = s4_corr1_ov ? s4_r0 : r1_full_acc[62:31];  // Q0.32
  end

  logic        s5_valid;
  logic [31:0] s5_r1;
  logic [31:0] s5_d_norm;
  logic [5:0]  s5_lz;
  logic        s5_is_zero, s5_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s5_valid <= 1'b0;
    end else begin
      s5_valid   <= s4_valid;
      s5_r1      <= r1_extracted;
      s5_d_norm  <= s4_d_norm;
      s5_lz      <= s4_lz;
      s5_is_zero <= s4_is_zero;
      s5_is_one  <= s4_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 6: d_norm × r1 — partial products (four 16×16)
  // ═══════════════════════════════════════════════════════════════
  logic [31:0] pp6_hh, pp6_hl, pp6_lh, pp6_ll;

  always_comb begin
    pp6_hh = s5_d_norm[31:16] * s5_r1[31:16];
    pp6_hl = s5_d_norm[31:16] * s5_r1[15:0];
    pp6_lh = s5_d_norm[15:0]  * s5_r1[31:16];
    pp6_ll = s5_d_norm[15:0]  * s5_r1[15:0];
  end

  logic        s6_valid;
  logic [31:0] s6_pp_hh, s6_pp_hl, s6_pp_lh, s6_pp_ll;
  logic [31:0] s6_r1;
  logic [5:0]  s6_lz;
  logic        s6_is_zero, s6_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s6_valid <= 1'b0;
    end else begin
      s6_valid   <= s5_valid;
      s6_pp_hh   <= pp6_hh;
      s6_pp_hl   <= pp6_hl;
      s6_pp_lh   <= pp6_lh;
      s6_pp_ll   <= pp6_ll;
      s6_r1      <= s5_r1;
      s6_lz      <= s5_lz;
      s6_is_zero <= s5_is_zero;
      s6_is_one  <= s5_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 7: accumulate dr1, extract dr1_q1_31, corr2 = 2 - dr1
  // ═══════════════════════════════════════════════════════════════
  logic [63:0] dr1_acc;
  logic [31:0] dr1_q1_31;
  logic [32:0] corr2;

  always_comb begin
    dr1_acc   = {s6_pp_hh, 32'b0} + {16'b0, s6_pp_hl, 16'b0}
              + {16'b0, s6_pp_lh, 16'b0} + {32'b0, s6_pp_ll};
    dr1_q1_31 = dr1_acc[63:32];
    corr2     = {1'b1, 32'h0000_0000} - {1'b0, dr1_q1_31};
  end

  logic        s7_valid;
  logic [31:0] s7_corr2;
  logic        s7_corr2_ov;
  logic [31:0] s7_r1;
  logic [5:0]  s7_lz;
  logic        s7_is_zero, s7_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s7_valid <= 1'b0;
    end else begin
      s7_valid    <= s6_valid;
      s7_corr2    <= corr2[31:0];
      s7_corr2_ov <= corr2[32];
      s7_r1       <= s6_r1;
      s7_lz       <= s6_lz;
      s7_is_zero  <= s6_is_zero;
      s7_is_one   <= s6_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 8: r1 × corr2 — partial products (four 16×16)
  // ═══════════════════════════════════════════════════════════════
  logic [31:0] mul8_a, mul8_b;
  logic [31:0] pp8_hh, pp8_hl, pp8_lh, pp8_ll;

  always_comb begin
    mul8_a = s7_r1;
    mul8_b = s7_corr2;
    pp8_hh = mul8_a[31:16] * mul8_b[31:16];
    pp8_hl = mul8_a[31:16] * mul8_b[15:0];
    pp8_lh = mul8_a[15:0]  * mul8_b[31:16];
    pp8_ll = mul8_a[15:0]  * mul8_b[15:0];
  end

  logic        s8_valid;
  logic [31:0] s8_pp_hh, s8_pp_hl, s8_pp_lh, s8_pp_ll;
  logic        s8_corr2_ov;
  logic [31:0] s8_r1;
  logic [5:0]  s8_lz;
  logic        s8_is_zero, s8_is_one;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s8_valid <= 1'b0;
    end else begin
      s8_valid    <= s7_valid;
      s8_pp_hh    <= pp8_hh;
      s8_pp_hl    <= pp8_hl;
      s8_pp_lh    <= pp8_lh;
      s8_pp_ll    <= pp8_ll;
      s8_corr2_ov <= s7_corr2_ov;
      s8_r1       <= s7_r1;
      s8_lz       <= s7_lz;
      s8_is_zero  <= s7_is_zero;
      s8_is_one   <= s7_is_one;
    end
  end

  // ═══════════════════════════════════════════════════════════════
  // Stage 9: accumulate r2, de-normalize, output
  // ═══════════════════════════════════════════════════════════════
  logic [63:0] r2_full_acc;
  logic [31:0] r2;
  logic [63:0] result_wide;
  logic [31:0] result_final;

  always_comb begin
    r2_full_acc = {s8_pp_hh, 32'b0} + {16'b0, s8_pp_hl, 16'b0}
               + {16'b0, s8_pp_lh, 16'b0} + {32'b0, s8_pp_ll};
    r2 = s8_corr2_ov ? s8_r1 : r2_full_acc[62:31];  // Q0.32

    // De-normalize
    result_wide = 64'd0;
    if (s8_is_zero) begin
      result_final = 32'hFFFF_FFFF;
    end else if (s8_is_one) begin
      result_final = 32'hFFFF_FFFF;
    end else if (s8_lz >= 6'd31) begin
      result_wide  = {32'd0, r2} << (s8_lz - 6'd31);
      if (result_wide[63:32] != 32'd0)
        result_final = 32'hFFFF_FFFF;
      else
        result_final = result_wide[31:0];
    end else begin
      result_final = r2 >> (6'd31 - s8_lz);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_valid        <= 1'b0;
      o_recip_q16_16 <= 32'd0;
    end else begin
      o_valid        <= s8_valid;
      o_recip_q16_16 <= result_final;
    end
  end

endmodule
