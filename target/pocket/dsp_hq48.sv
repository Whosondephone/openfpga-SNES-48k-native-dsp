// Native 48kHz S-DSP voice renderer
//
// The S-DSP (rtl/upstream/DSP.vhd) produces exactly one stereo sample per
// 32kHz period. Every voice in that period is evaluated once: its pitch counter
// (INTERP_POS) selects 4 decoded BRR samples and a Gaussian kernel phase, the
// result is scaled by the envelope, the voice volume, summed, scaled by the
// main volume and the echo return is added.
//
// This module re-renders that same mix directly at each 48kHz I2S frame
// instant instead of resampling the finished 32kHz mix:
//
//   * The real DSP keeps running unmodified. It still owns all game-visible
//     state (ARAM, registers, BRR decoding, envelopes, ENDX/ENVX/OUTX reads,
//     echo buffer writes), so games behave exactly as before.
//   * Read-only taps (HQ_TAP) expose, for every voice and every DSP period:
//     the decoded BRR samples as they are written into the DSP's BRR buffer,
//     the pitch counter at Gaussian lookup time, the exact pitch counter
//     advance applied that period (including pitch modulation), the envelope,
//     noise state and all volume registers.
//   * For every 48kHz output the time since the last DSP period is converted
//     into a fraction mu (0..1) of the measured DSP period. Each voice's pitch
//     counter is advanced by mu * advance, so the voice is sampled at its true
//     position at the 48kHz instant. Pitch is therefore exactly the pitch the
//     DSP plays: the voice moves through its BRR data at exactly the same rate.
//   * The voice is then evaluated with the DSP's own math: the identical
//     512-entry Gaussian table and 3+1 tap summing/wrap/clamp sequence, the
//     same envelope multiply, voice volume, per-voice saturating mix order,
//     main volume and final clamp.
//
// With mu = 0 the output is bit-identical to the DSP's own sample (verified in
// support/audio/sim_hq). The envelope is linearly interpolated between DSP
// periods; noise is held per DSP period (it is a 32kHz LFSR on hardware).
//
// The echo return is the one part that cannot be rendered at 48kHz: the echo
// buffer lives in ARAM, which the game can read, so the DSP must keep writing
// it at 32kHz. The echo contribution (FIR output * EVOL) is therefore band
// limited resampled to 48kHz with the polyphase audio_resampler and added.
//
// The voices are rendered 17 DSP periods (~0.53ms) behind the DSP: 2 periods
// so that all voice data for the period being rendered is complete, plus the
// group delay of the echo resampler, so the echo return lines up with the
// voices exactly as on the DSP's own output.

module dsp_hq48 #(
    parameter [15:0] NOMINAL_PERIOD_X32 = 16'd21430,
    parameter [15:0] MIN_PERIOD_X32 = 16'd19000,
    parameter [15:0] MAX_PERIOD_X32 = 16'd24000
) (
    input wire clk,
    input wire reset,

    // From the DSP
    input wire [127:0] hq_tap,
    input wire snd_rdy,  // One pulse per DSP sample period

    // Output sample request (one clk-wide pulse per 48kHz output frame)
    input wire out_req,

    output reg               out_valid = 0,
    output reg signed [15:0] out_l = 0,
    output reg signed [15:0] out_r = 0
);

  ////////////////////////////////////////////////////////////////////////////
  // Tap decode

  wire brr_we = hq_tap[0];
  wire [2:0] brr_v = hq_tap[3:1];
  wire [15:0] brr_d = hq_tap[19:4];

  wire pos_stb = hq_tap[20];
  wire [2:0] pos_v = hq_tap[23:21];
  wire [14:0] pos = hq_tap[38:24];

  wire gs_stb = hq_tap[39];
  wire [2:0] gs_v = hq_tap[42:40];
  wire [10:0] gs_env = hq_tap[53:43];
  wire gs_non = hq_tap[54];
  wire [14:0] gs_noise = hq_tap[69:55];

  wire reg_stb = hq_tap[70];
  wire [2:0] reg_type = hq_tap[73:71];
  wire [2:0] reg_v = hq_tap[76:74];
  wire [23:0] reg_data = hq_tap[100:77];

  ////////////////////////////////////////////////////////////////////////////
  // DSP period counter and period measurement

  reg [4:0] cnt = 0;
  reg [15:0] since_in = 0;
  reg [15:0] period_cnt = 0;
  reg [4:0] period_samples = 0;
  reg [15:0] period_x32 = NOMINAL_PERIOD_X32;

  always @(posedge clk) begin
    if (reset) begin
      cnt <= 0;
      since_in <= 0;
      period_cnt <= 0;
      period_samples <= 0;
      period_x32 <= NOMINAL_PERIOD_X32;
    end else begin
      if (since_in != 16'hFFFF) since_in <= since_in + 16'd1;
      if (period_cnt != 16'hFFFF) period_cnt <= period_cnt + 16'd1;

      if (snd_rdy) begin
        cnt <= cnt + 5'd1;
        since_in <= 16'd1;
        period_samples <= period_samples + 5'd1;
        if (period_samples == 5'd31) begin
          period_cnt <= 16'd1;
          if (period_cnt >= MIN_PERIOD_X32 && period_cnt <= MAX_PERIOD_X32) period_x32 <= period_cnt;
        end
      end
    end
  end

  ////////////////////////////////////////////////////////////////////////////
  // Decoded BRR sample history: 128 entries per voice. The DSP keeps 12; the
  // extra depth covers the render lag (at most 4 new samples per DSP period).

  reg signed [15:0] ring[1024];
  reg [6:0] wp[8];
  reg [9:0] ring_ra = 0;
  reg signed [15:0] ring_q = 0;

  integer i;
  initial begin
    for (i = 0; i < 1024; i = i + 1) ring[i] = 0;
    for (i = 0; i < 8; i = i + 1) wp[i] = 0;
  end

  always @(posedge clk) begin
    if (brr_we) begin
      ring[{brr_v, wp[brr_v]}] <= brr_d;
      wp[brr_v] <= wp[brr_v] + 7'd1;
    end
    ring_q <= ring[ring_ra];
  end

  ////////////////////////////////////////////////////////////////////////////
  // Per-period snapshots, SLOTS deep, indexed by DSP period
  //
  // Voice 0 is evaluated at the end of a DSP period (steps 30/31) and mixed
  // into the following period's output, so its data belongs to slot cnt + 1.

  localparam SLOT_BITS = 5;

  // Oldest Gaussian tap: the DSP uses (last written + 1 + pos[14:12]) mod 12,
  // the oldest of its 12 samples. Our write pointer is last written + 1.
  wire [6:0] pos_base = wp[pos_v] - 7'd12 + {4'b0, pos[14:12]};

  wire [SLOT_BITS-1:0] pos_slot = cnt + {{(SLOT_BITS - 1) {1'b0}}, pos_v == 3'd0};
  wire [SLOT_BITS-1:0] gs_slot = cnt + {{(SLOT_BITS - 1) {1'b0}}, gs_v == 3'd0};
  wire [SLOT_BITS-1:0] reg_slot = cnt + {{(SLOT_BITS - 1) {1'b0}}, reg_v == 3'd0};

  // Voice RAMs, address {slot, voice}
  reg [18:0] pos_ram[256];  // {ring index, 12 bit fraction}
  reg [23:0] vl_ram[256];  // {pitch counter advance, VOLL}
  reg [7:0] vr_ram[256];  // VOLR
  reg [26:0] gs_ram[256];  // {envelope, noise enable, noise}

  // Global per-period registers
  reg [7:0] mvoll_s[32];
  reg [7:0] mvolr_s[32];
  reg mute_s[32];

  initial begin
    for (i = 0; i < 256; i = i + 1) begin
      pos_ram[i] = 0;
      vl_ram[i] = 0;
      vr_ram[i] = 0;
      gs_ram[i] = 0;
    end
    for (i = 0; i < 32; i = i + 1) begin
      mvoll_s[i] = 0;
      mvolr_s[i] = 0;
      mute_s[i] = 0;
    end
  end

  reg signed [16:0] echo_l = 0, echo_r = 0;

  always @(posedge clk) begin
    if (pos_stb) pos_ram[{pos_slot, pos_v}] <= {pos_base, pos[11:0]};
    if (gs_stb) gs_ram[{gs_slot, gs_v}] <= {gs_env, gs_non, gs_noise};

    if (reg_stb) begin
      case (reg_type)
        3'd0: vl_ram[{reg_slot, reg_v}] <= reg_data[23:0];
        3'd1: vr_ram[{reg_slot, reg_v}] <= reg_data[7:0];
        3'd2: mvoll_s[cnt] <= reg_data[7:0];
        3'd3: mvolr_s[cnt] <= reg_data[7:0];
        3'd4: begin
          echo_l <= reg_data[16:0];
          mute_s[cnt] <= reg_data[17];
        end
        3'd5: echo_r <= reg_data[16:0];
        default: ;
      endcase
    end
  end

  reg [7:0] slot_ra = 0;
  reg [18:0] pos_q;
  reg [23:0] vl_q;
  reg [7:0] vr_q;
  reg [26:0] gs_q;

  always @(posedge clk) begin
    pos_q <= pos_ram[slot_ra];
    vl_q <= vl_ram[slot_ra];
    vr_q <= vr_ram[slot_ra];
    gs_q <= gs_ram[slot_ra];
  end

  ////////////////////////////////////////////////////////////////////////////
  // Echo return: 32kHz in ARAM, band limited resampled to 48kHz

  function automatic signed [15:0] clamp16(input signed [17:0] x);
    if (x > 18'sd32767) clamp16 = 16'sh7FFF;
    else if (x < -18'sd32768) clamp16 = 16'sh8000;
    else clamp16 = x[15:0];
  endfunction

  wire echo_valid;
  wire signed [15:0] echo_l48, echo_r48;

  audio_resampler #(
      .NOMINAL_PERIOD_X32(NOMINAL_PERIOD_X32),
      .MIN_PERIOD_X32(MIN_PERIOD_X32),
      .MAX_PERIOD_X32(MAX_PERIOD_X32)
  ) echo_resampler (
      .clk(clk),
      .reset(reset),
      .in_valid(snd_rdy),
      .in_l(clamp16({echo_l[16], echo_l})),
      .in_r(clamp16({echo_r[16], echo_r})),
      .out_req(out_req),
      .out_valid(echo_valid),
      .out_l(echo_l48),
      .out_r(echo_r48)
  );

  ////////////////////////////////////////////////////////////////////////////
  // Gaussian table (identical to the DSP's GTBL)

  reg [8:0] g_addr = 0;
  wire signed [11:0] g_q;

  dsp_hq48_gauss gauss (
      .clk (clk),
      .addr(g_addr),
      .q   (g_q)
  );

  ////////////////////////////////////////////////////////////////////////////
  // Renderer
  //
  // The dry voices are rendered RENDER_LAG DSP periods behind the DSP. This
  // matches the delay of the echo resampler, so the echo return keeps exactly
  // the same timing relative to the voices as on the DSP's own output.

  localparam [SLOT_BITS-1:0] RENDER_LAG = 5'd17;

  localparam ST_IDLE = 0;
  localparam ST_DIV = 1;
  localparam ST_SETUP = 2;
  localparam ST_V0 = 3;
  localparam ST_V1 = 4;
  localparam ST_V2 = 5;
  localparam ST_V3 = 6;
  localparam ST_V4 = 7;
  localparam ST_V5 = 8;
  localparam ST_TAP_ADDR = 9;
  localparam ST_TAP_WAIT = 10;
  localparam ST_TAP_MAC = 11;
  localparam ST_ENV = 12;
  localparam ST_MIX = 13;
  localparam ST_MAIN = 14;
  localparam ST_WAIT_ECHO = 15;

  reg [3:0] state = ST_IDLE;

  reg [31:0] div_rem;
  reg [31:0] div_num;
  reg [15:0] div_den;
  reg [16:0] div_quot;
  reg [5:0] div_count;
  reg mu_saturated;
  wire [32:0] div_trial = {div_rem[31:0], div_num[31]} - {17'b0, div_den};

  reg [15:0] mu;
  reg [SLOT_BITS-1:0] slot_k;
  reg [2:0] v;
  reg [1:0] tap;

  // Latched voice data
  reg [18:0] cur_pos;
  reg [15:0] cur_adv;
  reg signed [7:0] cur_voll, cur_volr;
  reg [10:0] env0, env1;
  reg non;
  reg [14:0] noise;

  reg [18:0] a;  // Interpolated absolute position {ring index, fraction}
  reg [10:0] env;

  reg signed [16:0] sum012;
  reg signed [15:0] voice_out;
  reg signed [15:0] tout;
  reg signed [15:0] mout_l, mout_r;

  reg echo_done;
  reg signed [15:0] echo_hold_l, echo_hold_r;

  wire [31:0] adv_mu = cur_adv * mu;
  wire signed [11:0] env_delta = $signed({1'b0, env1}) - $signed({1'b0, env0});
  wire signed [28:0] env_delta_mu = env_delta * $signed({1'b0, mu});

  wire [7:0] frac = a[11:4];
  wire [6:0] idx = a[18:12];

  wire signed [27:0] g_prod = g_q * ring_q;
  wire signed [27:0] g_shift = g_prod >>> 11;
  wire signed [16:0] g_term = g_shift[16:0];

  wire signed [16:0] gsum_pre = {sum012[15], sum012[15:0]} + g_term;
  wire signed [15:0] gsum = clamp16({gsum_pre[16], gsum_pre});

  wire signed [27:0] env_prod = voice_out * $signed({1'b0, env});
  wire signed [27:0] env_shift = env_prod >>> 11;
  wire signed [28:0] env_delta_shift = env_delta_mu >>> 16;
  wire [10:0] env_interp = env0 + env_delta_shift[10:0];

  wire signed [23:0] vl_prod = tout * cur_voll;
  wire signed [23:0] vr_prod = tout * cur_volr;
  wire signed [23:0] vl_shift = vl_prod >>> 7;
  wire signed [23:0] vr_shift = vr_prod >>> 7;
  wire signed [16:0] vl_term = vl_shift[16:0];
  wire signed [16:0] vr_term = vr_shift[16:0];

  wire signed [7:0] mvoll = mvoll_s[slot_k];
  wire signed [7:0] mvolr = mvolr_s[slot_k];
  wire mute = mute_s[slot_k];

  wire signed [23:0] ml_prod = mout_l * mvoll;
  wire signed [23:0] mr_prod = mout_r * mvolr;
  wire signed [23:0] ml_shift = ml_prod >>> 7;
  wire signed [23:0] mr_shift = mr_prod >>> 7;

  wire signed [15:0] echo_now_l = echo_valid ? echo_l48 : echo_hold_l;
  wire signed [15:0] echo_now_r = echo_valid ? echo_r48 : echo_hold_r;

  always @(posedge clk) begin
    out_valid <= 0;

    if (echo_valid) begin
      echo_done   <= 1;
      echo_hold_l <= echo_l48;
      echo_hold_r <= echo_r48;
    end

    if (reset) begin
      state <= ST_IDLE;
      out_l <= 0;
      out_r <= 0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (out_req) begin
            slot_k <= cnt - RENDER_LAG;
            echo_done <= 0;

            div_num <= {since_in - 16'd1, 16'b0} << 5;
            div_den <= period_x32;
            div_rem <= 0;
            div_quot <= 0;
            div_count <= 0;
            mu_saturated <= since_in >= 16'd2048;
            state <= since_in >= 16'd2048 ? ST_SETUP : ST_DIV;
          end
        end

        ST_DIV: begin
          div_num <= {div_num[30:0], 1'b0};
          if (!div_trial[32]) begin
            div_rem  <= div_trial[31:0];
            div_quot <= {div_quot[15:0], 1'b1};
          end else begin
            div_rem  <= {div_rem[30:0], div_num[31]};
            div_quot <= {div_quot[15:0], 1'b0};
          end
          if (div_quot[16]) div_quot <= 17'h1FFFF;
          div_count <= div_count + 6'd1;
          if (div_count == 6'd31) state <= ST_SETUP;
        end

        ST_SETUP: begin
          mu <= (mu_saturated || div_quot[16]) ? 16'hFFFF : div_quot[15:0];
          v <= 0;
          mout_l <= 0;
          mout_r <= 0;
          state <= ST_V0;
        end

        // Fetch this voice's data for period k, then its envelope for k + 1
        ST_V0: begin
          slot_ra <= {slot_k, v};
          state <= ST_V1;
        end

        ST_V1: begin
          slot_ra <= {slot_k + 5'd1, v};
          state <= ST_V2;
        end

        ST_V2: begin
          cur_pos <= pos_q;
          {cur_adv, cur_voll} <= vl_q;
          cur_volr <= vr_q;
          {env0, non, noise} <= gs_q;
          state <= ST_V3;
        end

        ST_V3: begin
          env1  <= gs_q[26:16];
          state <= ST_V4;
        end

        ST_V4: begin
          // Pitch counter at the output instant
          a <= cur_pos + {3'b0, adv_mu[31:16]};

          // Envelope: zero stays zero (key on/off cuts), otherwise linear
          if (env0 == 0) env <= 0;
          else env <= env_interp;

          tap   <= 0;
          state <= ST_TAP_ADDR;
        end

        ST_TAP_ADDR: begin
          ring_ra <= {v, idx + {5'b0, tap}};
          case (tap)
            2'd0: g_addr <= {1'b0, ~frac};  // 255 - f
            2'd1: g_addr <= {1'b1, ~frac};  // 511 - f
            2'd2: g_addr <= {1'b1, frac};  // 256 + f
            2'd3: g_addr <= {1'b0, frac};  // f
          endcase
          state <= ST_TAP_WAIT;
        end

        ST_TAP_WAIT: state <= ST_TAP_MAC;

        ST_TAP_MAC: begin
          tap <= tap + 2'd1;
          case (tap)
            2'd0: sum012 <= g_term;
            2'd1, 2'd2: sum012 <= sum012 + g_term;
            2'd3: voice_out <= non ? {noise, 1'b0} : (gsum & 16'hFFFE);
          endcase
          state <= tap == 2'd3 ? ST_ENV : ST_TAP_ADDR;
        end

        ST_ENV: begin
          tout  <= {env_shift[15:1], 1'b0};
          state <= ST_MIX;
        end

        ST_MIX: begin
          mout_l <= clamp16({{2{mout_l[15]}}, mout_l} + {vl_term[16], vl_term});
          mout_r <= clamp16({{2{mout_r[15]}}, mout_r} + {vr_term[16], vr_term});
          v <= v + 3'd1;
          state <= v == 3'd7 ? ST_MAIN : ST_V0;
        end

        ST_MAIN: begin
          // DSP: resize(shift_right(MOUT * MVOL, 7), 16) keeps sign + low 15 bits
          mout_l <= {ml_shift[23], ml_shift[14:0]};
          mout_r <= {mr_shift[23], mr_shift[14:0]};
          state  <= ST_WAIT_ECHO;
        end

        ST_WAIT_ECHO: begin
          if (echo_done || echo_valid) begin
            if (mute) begin
              out_l <= 0;
              out_r <= 0;
            end else begin
              out_l <= clamp16({{2{mout_l[15]}}, mout_l} + {{2{echo_now_l[15]}}, echo_now_l});
              out_r <= clamp16({{2{mout_r[15]}}, mout_r} + {{2{echo_now_r[15]}}, echo_now_r});
            end
            out_valid <= 1;
            state <= ST_IDLE;
          end
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule
