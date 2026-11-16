`timescale 1ns/1ps
module tb_hq;
  reg clk = 0;
  always #23.28 clk = ~clk;   // ~21.477 MHz
  reg rst_n = 0;

  reg [15:0] smp_a = 16'h00F0;
  reg [7:0] smp_do = 0;
  reg smp_we = 1;
  wire smp_en_f;
  wire [15:0] ram_a;
  wire [7:0] ram_d;
  wire ram_ce_n, ram_oe_n, ram_we_n;
  wire [7:0] ram_q = aram[ram_a];
  wire [15:0] audio_l, audio_r;
  wire snd_rdy;
  wire [127:0] hq_tap;

  reg [7:0] aram[65536];
  always @(posedge clk) begin
    if (!ram_ce_n && !ram_we_n) aram[ram_a] <= ram_d;
  end

  DSP dsp (
      .CLK(clk), .RST_N(rst_n), .ENABLE(1'b1), .PAL(1'b0), .FREQ(1'b0),
      .SMP_A(smp_a), .SMP_DO(smp_do), .SMP_WE(smp_we), .RAM_Q(ram_q),
      .IO_ADDR(17'd0), .IO_DAT(16'd0), .IO_WR(1'b0),
      .SS_ADDR(9'd0), .SS_REGS_SEL(1'b0), .SS_WR(1'b0), .SS_DI(8'd0),
      .SMP_EN_F(smp_en_f), .SMP_EN_R(), .SMP_DI(), .SMP_CE(),
      .RAM_A(ram_a), .RAM_D(ram_d), .RAM_CE_N(ram_ce_n), .RAM_OE_N(ram_oe_n), .RAM_WE_N(ram_we_n),
      .LRCK(), .BCK(), .SDAT(), .SS_DO(),
      .AUDIO_L(audio_l), .AUDIO_R(audio_r), .SND_RDY(snd_rdy), .HQ_TAP(hq_tap));

  reg out_req = 0;
  wire out_valid;
  wire signed [15:0] out_l, out_r;

  dsp_hq48 hq (
      .clk(clk), .reset(!rst_n), .hq_tap(hq_tap), .snd_rdy(snd_rdy),
      .out_req(out_req), .out_valid(out_valid), .out_l(out_l), .out_r(out_r));

  // Reference: the shipping resampler fed by the DSP's 32kHz output
  wire rs_valid;
  wire signed [15:0] rs_l, rs_r;
  audio_resampler rs (
      .clk(clk), .reset(!rst_n), .in_valid(snd_rdy), .in_l(audio_l), .in_r(audio_r),
      .out_req(out_req), .out_valid(rs_valid), .out_l(rs_l), .out_r(rs_r));

  reg [15:0] regs[256];
  integer fev, fbrr, mode, nsamp, fhw, fhq, frs, i, n_out;
  reg [31:0] acc;
  reg snd_rdy_d;
  reg [63:0] cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;
  reg [63:0] t_req; integer max_lat = 0;
  always @(posedge clk) begin
    if (out_req) t_req <= cyc;
    if (out_valid && cyc - t_req > max_lat) max_lat = cyc - t_req;
  end
  final $display("max render latency %0d cycles", max_lat);

  task automatic dsp_write(input [15:0] a, input [7:0] d);
    begin
      @(posedge clk); while (!smp_en_f) @(posedge clk);
      smp_a <= a; smp_do <= d; smp_we <= 0;
      @(posedge clk); while (smp_en_f) @(posedge clk);
      smp_a <= 16'h00F0; smp_we <= 1;
      repeat (30) @(posedge clk);
    end
  endtask

  // 48kHz request generator (mode 1) or one request right after each DSP sample (mode 0)
  always @(posedge clk) begin
    snd_rdy_d <= snd_rdy;
    out_req <= 0;
    if (mode == 0) out_req <= snd_rdy;
    else begin
      if (acc + 32'd48000 >= 32'd21477270) begin acc <= acc + 32'd48000 - 32'd21477270; out_req <= 1; end
      else acc <= acc + 32'd48000;
    end
  end

  always @(posedge clk) begin
    if (rst_n) begin
      if (snd_rdy) $fdisplay(fev, "%0d", hq.echo_l);
      if (snd_rdy) $fdisplay(fhw, "%0d %0d %0d", cyc, $signed(audio_l), $signed(audio_r));
      if (out_valid) $fdisplay(fhq, "%0d %0d %0d", cyc, out_l, out_r);
      if (rs_valid) $fdisplay(frs, "%0d %0d %0d", cyc, rs_l, rs_r);
      if (out_valid) n_out = n_out + 1;
      if (hq_tap[0] && hq_tap[3:1]==0) $fdisplay(fbrr, "%0d", $signed(hq_tap[19:4]));
    end
  end

  initial begin
    if (!$value$plusargs("mode=%d", mode)) mode = 0;
    if (!$value$plusargs("n=%d", nsamp)) nsamp = 4000;
    acc = 0; n_out = 0;
    $readmemh("aram.hex", aram);
    $readmemh("regs.hex", regs);
    fhw = $fopen("hw.txt", "w"); fbrr = $fopen("brr.txt", "w"); fev = $fopen("ev.txt", "w"); fhq = $fopen("hq.txt", "w"); frs = $fopen("rs.txt", "w");
    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (2000) @(posedge clk);
    for (i = 0; regs[i] != 16'hFFFF; i = i + 1) begin
      dsp_write(16'h00F2, regs[i][15:8]);
      dsp_write(16'h00F3, regs[i][7:0]);
    end
    while (n_out < nsamp) @(posedge clk);
    $fclose(fhw); $fclose(fhq); $fclose(frs);
    $finish;
  end
endmodule
