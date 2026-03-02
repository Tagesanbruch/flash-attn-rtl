package fa_fixed_point_pkg;
  function automatic logic signed [15:0] sat16_signed(input logic signed [31:0] x);
    if (x > 32'sd32767) begin
      return 16'sd32767;
    end
    if (x < -32'sd32768) begin
      return -16'sd32768;
    end
    return x[15:0];
  endfunction

  function automatic logic [31:0] sat32_unsigned(input logic [63:0] x);
    if (x > 64'hFFFF_FFFF) begin
      return 32'hFFFF_FFFF;
    end
    return x[31:0];
  endfunction
endpackage
