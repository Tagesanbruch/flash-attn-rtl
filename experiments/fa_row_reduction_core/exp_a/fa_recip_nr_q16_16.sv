module fa_recip_nr_q16_16 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        i_valid,
  input  logic [31:0] i_x_q16_16,
  output logic        o_valid,
  output logic [31:0] o_recip_q16_16
);
  // Newton-Raphson reciprocal: 3-stage pipeline
  //
  // Formats:
  //   d_norm: Q1.31 (32 bits), d_real = d_norm/2^31 in [1.0, 2.0)
  //   r:      Q0.32 (32 bits), r_real = r/2^32 in (0.5, 1.0]
  //   Products: Q1.31 × Q0.32 = Q1.63 (64-bit unsigned)
  //
  // Algorithm:
  //   1. CLZ normalize: d_norm = x << lz, d_norm[31]=1
  //   2. 32-entry LUT: r0 ≈ 1/d_real in Q0.32 (~6 bits accuracy)
  //   3. NR iteration ×2: r_new = r_old * (2 - d_norm * r_old)
  //      d*r product Q1.63, extract Q1.31 = bits [63:32]
  //      r*corr product Q1.63, extract Q0.32 = bits [62:31]
  //   4. De-normalize: Q16.16(1/x) = r2 × 2^(lz-31)

  // ─── Stage 1: CLZ + LUT ───────────────────────────────────────
  logic        s1_valid;
  logic [31:0] s1_d_norm;     // d_norm in Q1.31 (d_real in [1.0, 2.0))
  logic [31:0] s1_r0;         // initial estimate in Q0.32 (in (0.5, 1.0])
  logic [5:0]  s1_lz;
  logic        s1_is_zero;
  logic        s1_is_one;

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

  logic [5:0]  lz;
  logic [31:0] d_norm;
  logic [31:0] r0_lut;

  always_comb begin
    lz     = clz32(i_x_q16_16);
    d_norm = i_x_q16_16 << lz;

    // 32-entry LUT indexed by d_norm[30:26] (5 bits)
    // d_norm[31]=1 always, so d_real ∈ [1.0, 2.0)
    // LUT[k] = round(2^32 / d_mid), d_mid = 1 + (2k+1)/64
    case (d_norm[30:26])
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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid   <= 1'b0;
      s1_d_norm  <= 32'd0;
      s1_r0      <= 32'd0;
      s1_lz      <= 6'd0;
      s1_is_zero <= 1'b0;
      s1_is_one  <= 1'b0;
    end else begin
      s1_valid   <= i_valid;
      s1_d_norm  <= d_norm;
      s1_r0      <= r0_lut;
      s1_lz      <= lz;
      s1_is_zero <= (i_x_q16_16 == 32'd0);
      s1_is_one  <= (i_x_q16_16 == 32'd1);
    end
  end

  // ─── Stage 2: NR iteration 1 ──────────────────────────────────
  // r1 = r0 * (2 - d_norm * r0)
  //
  // d_norm (Q1.31) × r0 (Q0.32) = Q1.63 (64-bit)
  // Extract Q1.31 from Q1.63: bits [63:32]
  // correction = 2.0 - d*r (33-bit, Q2.31)
  // r1 = r0 (Q0.32) × correction[31:0] (Q1.31) = Q1.63
  // Extract Q0.32 from Q1.63: bits [62:31] (since r < 1.0, bit 63 = 0)
  logic        s2_valid;
  logic [31:0] s2_r1;
  logic [31:0] s2_d_norm;
  logic [5:0]  s2_lz;
  logic        s2_is_zero;
  logic        s2_is_one;

  logic [63:0] dr0;
  logic [31:0] dr0_q1_31;
  logic [32:0] corr1_q1_31;
  logic [63:0] r1_full;

  always_comb begin
    dr0         = s1_d_norm * s1_r0;               // Q1.31 × Q0.32 = Q1.63
    dr0_q1_31   = dr0[63:32];                      // Extract Q1.31 from Q1.63
    corr1_q1_31 = {1'b1, 32'h0000_0000} - {1'b0, dr0_q1_31};  // 2.0 - d*r
    r1_full     = s1_r0 * corr1_q1_31[31:0];       // Q0.32 × Q1.31 = Q1.63
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_valid   <= 1'b0;
      s2_r1      <= 32'd0;
      s2_d_norm  <= 32'd0;
      s2_lz      <= 6'd0;
      s2_is_zero <= 1'b0;
      s2_is_one  <= 1'b0;
    end else begin
      s2_valid   <= s1_valid;
      if (corr1_q1_31[32])
        s2_r1 <= s1_r0;             // correction ≥ 2.0, clamp
      else
        s2_r1 <= r1_full[62:31];    // Q0.32 from Q1.63
      s2_d_norm  <= s1_d_norm;
      s2_lz      <= s1_lz;
      s2_is_zero <= s1_is_zero;
      s2_is_one  <= s1_is_one;
    end
  end

  // ─── Stage 3: NR iteration 2 + de-normalize ───────────────────
  logic [63:0] dr1;
  logic [31:0] dr1_q1_31;
  logic [32:0] corr2_q1_31;
  logic [63:0] r2_full;
  logic [31:0] r2;

  logic [63:0] result_wide;
  logic [31:0] result_final;

  always_comb begin
    dr1         = s2_d_norm * s2_r1;               // Q1.31 × Q0.32 = Q1.63
    dr1_q1_31   = dr1[63:32];                      // Extract Q1.31 from Q1.63
    corr2_q1_31 = {1'b1, 32'h0000_0000} - {1'b0, dr1_q1_31};  // 2.0 - d*r
    r2_full     = s2_r1 * corr2_q1_31[31:0];       // Q0.32 × Q1.31 = Q1.63
    r2          = r2_full[62:31];                   // Extract Q0.32

    // De-normalize: Q16.16(1/x) = r2 × 2^(lz-31)
    //   if lz >= 31: result = r2 << (lz - 31)
    //   if lz <  31: result = r2 >> (31 - lz)
    result_wide = 64'd0;

    if (s2_is_zero) begin
      result_final = 32'hFFFF_FFFF;
    end else if (s2_is_one) begin
      result_final = 32'hFFFF_FFFF;                // 1/(1/65536) overflows Q16.16, saturate
    end else if (s2_lz >= 6'd31) begin
      result_wide = {32'd0, r2} << (s2_lz - 6'd31);
      if (result_wide[63:32] != 32'd0)
        result_final = 32'hFFFF_FFFF;              // overflow saturation
      else
        result_final = result_wide[31:0];
    end else begin
      result_final = r2 >> (6'd31 - s2_lz);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      o_valid        <= 1'b0;
      o_recip_q16_16 <= 32'd0;
    end else begin
      o_valid        <= s2_valid;
      o_recip_q16_16 <= result_final;
    end
  end

endmodule
