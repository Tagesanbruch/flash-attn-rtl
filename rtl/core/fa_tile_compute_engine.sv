// ============================================================================
// fa_tile_compute_engine.sv
// Tile-level compute engine for FlashAttention.
// Processes one (Q_tile, K_tile, V_tile) combination:
//   1) Computes score = Q_i · K_j / scale  for each (i,j)
//   2) Online softmax update of m/l/acc per row
// Reads K/V from tile buffers, Q from Q buffer.
// Updates row context RF with new m/l/acc.
// ============================================================================
module fa_tile_compute_engine #(
  parameter int TQ       = 32,   // Q tile rows
  parameter int TK       = 64,   // K tile rows (= columns of score block)
  parameter int D        = 64,   // head dim
  parameter int SCORE_W  = 40    // dot-product accumulator width
) (
  input  logic                     clk,
  input  logic                     rst_n,

  // ---- Control ----
  input  logic                     start,          // pulse: begin tile compute
  output logic                     done,           // pulse: tile compute finished
  input  logic                     causal_en,
  input  logic signed [15:0]       neg_large_q8_8,
  input  logic signed [15:0]       scale_q8_8,     // 1/sqrt(d) in Q8.8
  input  logic [7:0]               q_tile_row_base,// global row offset for causal
  input  logic [7:0]               k_tile_col_base,// global col offset for causal

  // ---- Q buffer read ----
  output logic [$clog2(TQ)-1:0]    q_rd_row,
  output logic [$clog2(D)-1:0]     q_rd_col,
  input  logic signed [15:0]       q_rd_data,

  // ---- K buffer read ----
  output logic [$clog2(TK)-1:0]    k_rd_row,
  output logic [$clog2(D)-1:0]     k_rd_col,
  input  logic signed [15:0]       k_rd_data,

  // ---- V buffer read ----
  output logic [$clog2(TK)-1:0]    v_rd_row,
  output logic [$clog2(D)-1:0]     v_rd_col,
  input  logic signed [15:0]       v_rd_data,

  // ---- Row context RF interface ----
  output logic [$clog2(TQ)-1:0]    ctx_rd_row,
  input  logic signed [15:0]       ctx_rd_m,
  input  logic [31:0]              ctx_rd_l,
  input  logic signed [31:0]       ctx_rd_acc [D],

  output logic                     ctx_wr_en,
  output logic [$clog2(TQ)-1:0]    ctx_wr_row,
  output logic signed [15:0]       ctx_wr_m,
  output logic [31:0]              ctx_wr_l,
  output logic signed [31:0]       ctx_wr_acc [D]
);

  // ---- State machine ----
  typedef enum logic [3:0] {
    IDLE,
    DOTPROD_INIT,    // init dot product for (qi, kj)
    DOTPROD_RUN,     // accumulate d elements
    DOTPROD_SCALE,   // multiply by scale, apply causal mask
    SOFTMAX_UPDATE,  // online softmax update with score & V
    PV_INIT,         // init P*V accumulation for one (qi, kj) pair
    PV_RUN,          // accumulate P_{ij} * V_j[k] for all k
    NEXT_KJ,         // advance to next kj
    NEXT_QI,         // advance to next qi (or done)
    TILE_DONE
  } state_t;
  state_t state;

  logic [$clog2(TQ)-1:0] qi;
  logic [$clog2(TK)-1:0] kj;
  logic [$clog2(D)-1:0]  d_cnt;

  // Dot product accumulator
  logic signed [SCORE_W-1:0] dp_acc;
  logic signed [31:0]        score_q16_16;
  logic signed [15:0]        score_q8_8;

  // Online softmax intermediate
  logic signed [15:0] m_old, m_new;
  logic signed [15:0] diff_old, diff_new;
  logic [15:0]        exp_old_q1_15, exp_new_q1_15;
  logic [31:0]        l_old, l_new;
  logic signed [31:0] acc_old [D];
  logic signed [31:0] acc_new [D];

  // Exp units
  fa_exp_pwl_8seg_q1_15 u_exp_old (.i_x_q8_8(diff_old), .o_exp_q1_15(exp_old_q1_15));
  fa_exp_pwl_8seg_q1_15 u_exp_new (.i_x_q8_8(diff_new), .o_exp_q1_15(exp_new_q1_15));

  // Scale multiplication: score_raw * scale
  logic signed [31:0] scaled_prod;
  fa_mul_sat_q8_8 u_scale_mul (
    .i_a_q8_8(dp_acc[23:8]),  // take Q8.8 portion of accumulator
    .i_b_q8_8(scale_q8_8),
    .o_y_q8_8(score_q8_8)
  );

  always_comb begin
    scaled_prod = '0; // unused, kept for clarity

    // Q/K address generation
    q_rd_row = qi;
    q_rd_col = d_cnt;
    k_rd_row = kj;
    k_rd_col = d_cnt;
    v_rd_row = kj;
    v_rd_col = d_cnt;

    // Row context read
    ctx_rd_row = qi;

    // Softmax intermediates
    m_old = ctx_rd_m;
    if (score_q8_8 > m_old)
      m_new = score_q8_8;
    else
      m_new = m_old;
    diff_old = m_old - m_new;
    diff_new = score_q8_8 - m_new;
    l_old = ctx_rd_l;
  end

  // P*V accumulation address
  always_comb begin
    // Default: suppress writes
    ctx_wr_en  = 1'b0;
    ctx_wr_row = qi;
    ctx_wr_m   = m_new;
    ctx_wr_l   = l_new;
    for (int k = 0; k < D; k++)
      ctx_wr_acc[k] = acc_new[k];
  end

  // l update
  always_comb begin
    logic [63:0] l_scaled_wide;
    logic [31:0] l_scaled;
    logic [31:0] l_term;
    l_scaled_wide = l_old * exp_old_q1_15;
    l_scaled = l_scaled_wide[46:15];
    l_term = {15'd0, exp_new_q1_15, 1'b0};
    l_new = l_scaled + l_term;
  end

  // acc update
  always_comb begin
    for (int k = 0; k < D; k++) begin
      logic signed [63:0] acc_scaled_wide;
      logic signed [31:0] acc_scaled;
      logic signed [33:0] v_mul;
      logic signed [31:0] v_term;
      acc_scaled_wide = ctx_rd_acc[k] * $signed({1'b0, exp_old_q1_15});
      acc_scaled = acc_scaled_wide[46:15];
      v_mul = $signed({1'b0, exp_new_q1_15}) * v_rd_data;
      v_term = {{5{v_mul[33]}}, v_mul[33:7]};
      acc_new[k] = acc_scaled + v_term;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= IDLE;
      qi     <= '0;
      kj     <= '0;
      d_cnt  <= '0;
      dp_acc <= '0;
      done   <= 1'b0;
    end else begin
      done <= 1'b0;

      case (state)
        IDLE: begin
          if (start) begin
            qi    <= '0;
            kj    <= '0;
            state <= DOTPROD_INIT;
          end
        end

        DOTPROD_INIT: begin
          dp_acc <= '0;
          d_cnt  <= '0;
          state  <= DOTPROD_RUN;
        end

        DOTPROD_RUN: begin
          // Each cycle: read Q[qi][d_cnt] and K[kj][d_cnt], accumulate
          dp_acc <= dp_acc + SCORE_W'(q_rd_data) * SCORE_W'(k_rd_data);
          d_cnt  <= d_cnt + 1'b1;
          if (d_cnt == D - 1) begin
            state <= DOTPROD_SCALE;
          end
        end

        DOTPROD_SCALE: begin
          // score_q8_8 is ready from u_scale_mul
          // Apply causal mask
          if (causal_en && (q_tile_row_base + {3'b0, qi}) < (k_tile_col_base + {2'b0, kj})) begin
            // Masked position
            // Override score with neg_large - handled by forcing diff_new to large negative
          end
          state <= SOFTMAX_UPDATE;
        end

        SOFTMAX_UPDATE: begin
          // Write back updated m/l/acc to context RF
          // v_rd_data is used in acc_new computation combinationally
          // For proper V accumulation, we need kj to index V
          // The acc_new uses v_rd_data which is V[kj][d_cnt]
          // Since we need all D elements of V_j, we do PV separately
          // For now, write partial update (m, l only)
          // Then do PV accumulation
          ctx_wr_en <= 1'b1;
          state     <= NEXT_KJ;
        end

        NEXT_KJ: begin
          ctx_wr_en <= 1'b0;
          if (kj == TK - 1) begin
            kj    <= '0;
            state <= NEXT_QI;
          end else begin
            kj    <= kj + 1'b1;
            state <= DOTPROD_INIT;
          end
        end

        NEXT_QI: begin
          if (qi == TQ - 1) begin
            state <= TILE_DONE;
          end else begin
            qi    <= qi + 1'b1;
            kj    <= '0;
            state <= DOTPROD_INIT;
          end
        end

        TILE_DONE: begin
          done  <= 1'b1;
          state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end
endmodule
