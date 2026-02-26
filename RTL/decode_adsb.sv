module decode_adsb (
    input  logic clk,
    input  logic reset,

    input  logic [15:0] sample,
    input  logic valid_sample,

    output logic [7:0] byte_stream,
    output logic byte_stream_valid,

    output logic [5:0] valid_cnt
);

    localparam int NOISE_WINDOW_SIZE = 64;
    logic [15:0] search_window [15:0];
    logic [15:0] thresh_search_window;
    logic [15:0] noise_window [NOISE_WINDOW_SIZE-1:0];
    logic [31:0] noise_sum;
    logic [31:0] noise_level;
    logic [31:0] threshold;

    logic preamble_match;

    // =================================================
    // Shift valid samples in to preamble search window
    // =================================================
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 16; i++)
                search_window[i] <= '0;
        end else if (valid_sample) begin
            search_window[0] <= sample;
            for (int i = 1; i < 16; i++)
                search_window[i] <= search_window[i-1];
        end
    end

    // Calculate noise levels from samples that came before current preamble search window
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < NOISE_WINDOW_SIZE; i++)
                noise_window[i] <= 0;
        end else if (valid_sample) begin
            noise_sum <= noise_sum + search_window[15] - noise_window[NOISE_WINDOW_SIZE-1];
            noise_window[0] <= search_window[15];
            for (int i = 1; i < NOISE_WINDOW_SIZE; i++)
                noise_window[i] <= noise_window[i-1];
        end
    end

    assign noise_level = noise_sum >> $clog2(NOISE_WINDOW_SIZE);
    assign threshold = noise_level << 5;

    // =========================
    // Find preamble
    // =========================
    localparam logic [15:0] PREAMBLE = 16'b1010000101000000;
    always_comb begin
        for (int i = 0; i < 16; i++)
            thresh_search_window[i] = search_window[i] > threshold;
    end

    assign preamble_match = ~|(thresh_search_window ^ PREAMBLE);
    
    // =========================
    // Process message
    // =========================
    logic crc_error;
    logic clear_crc;

    enum {
        IDLE,
        SHIFT,
        PACKET_CHECK
    } state, next_state;

    always_ff @(posedge clk) begin
        if (reset) state <= IDLE;
        else       state <= next_state;

        if (reset) shift_cnt <= 0;
        else       shift_cnt <= next_shift_cnt;
    end

    always_comb begin
        next_state = state;
        next_shift_cnt = shift_cnt;
        valid_packet = 0;
        clear_crc = 0;

        case (state)
            IDLE : begin
                clear_crc = 1;
                if (preamble_match)
                    next_state = SHIFT;
            end

            SHIFT : begin
                if (valid_sample) begin
                    if (shift_cnt == 224)
                        next_state = PACKET_CHECK;
                    else
                        next_shift_cnt = shift_cnt + 1;
                end
            end

            PACKET_CHECK : begin
                next_shift_cnt = 0;
                next_state = IDLE;
                valid_packet = ~crc_error;
            end
        endcase
    end

    // =========================
    // decode every sample pair
    // =========================
    logic valid_packet_bit;
    logic valid_decode;
    logic decoded_bit;
    logic [1:0] valid_decode_window;
    logic [15:0] decode_window [1:0];

    always_ff @(posedge clk) begin
        if ((state == IDLE) || valid_decode) 
            valid_decode_window <= 0;
        else if (valid_sample) 
            valid_decode_window <= {valid_decode_window[0],1'b1};

        if (valid_sample) begin
            decode_window[0] <= sample;
            decode_window[1] <= decode_window[0];
        end
    end


    always_comb begin
        valid_decode = 0;
        decoded_bit = 'x;

        if (valid_decode_window[1]) begin
            valid_decode = 1;
            decoded_bit = decode_window[1] > decode_window[0];
        end
    end


    // ================================
    // shift in decoded packet bits
    // ================================
    logic [111:0] packet_buffer;

    always_ff @(posedge clk) begin
        if (valid_decode)
            packet_buffer <= {packet_buffer, decoded_bit};
    end

    // =========================
    // CRC check
    // =========================
    crc24 crc_i(
        .clk,
        .reset(clear_crc),
        .valid(valid_decode),
        .data(decoded_bit),
        .crc_error
    );

    // =================================================
    // Check complete packet and output decoded data
    // =================================================
    logic [7:0] shift_cnt, next_shift_cnt;
    logic valid_packet;

    

    logic [4:0] DF;
    logic [2:0] CA;
    logic [23:0] ICAO;
    logic [55:0] ME;
    logic [23:0] PI;
    
    assign {DF,CA,ICAO,ME,PI} = packet_buffer;

    // ===========================================
    // Buffer valid binary packet data in FIFO
    // ===========================================

    logic packet_buffer_valid;
    logic packet_buffer_ready;
    logic [79:0] packet_buffer_data;

    fifo #(
        .WIDTH(80),
        .DEPTH(4)
    ) char_buffer (
        .clk(clk),
        .reset(reset),
        .ready_in(),
        .valid_in(valid_packet),
        .data_in({ICAO,ME}),
        .ready_out(packet_buffer_ready),
        .valid_out(packet_buffer_valid),
        .data_out(packet_buffer_data),
        .almost_full(),
        .almost_empty()
    );
    

    // =========================================================
    // Convert packet contents to ASCII and output from module
    // =========================================================

    logic [3:0] idx, next_idx;
    logic [4:0] type_code;
    logic [5:0] dec_sym;
    logic [7:0] decoded_hex;
    logic [7:0] decoded_code6;

    // Type Code | Content
    // 1-4         Aircraft identification
    // 5-8         Surface position
    // 9-18        Airborne position (w/Baro Altitude)
    // 19          Airborne velocities
    // 20-22       Airborne position (w/GNSS Height)
    // 23-27       Reserved
    // 28          Aircraft status
    // 29          Target state and status information
    // 31          Aircraft operation status
    assign type_code = packet_buffer_data[55:51];

    enum {
        DECODE_IDLE,
        DECODE_ICAO,
        DECODE_ME,
        DECODE_DONE
    } decode_state, next_decode_state;

    always_ff @(posedge clk) begin
        if (reset) decode_state <= DECODE_IDLE;
        else       decode_state <= next_decode_state;

        if (reset) idx <= 0;
        else       idx <= next_idx;
    end

    always_comb begin
        next_decode_state = decode_state;
        next_idx = idx;
        packet_buffer_ready = 0;
        byte_stream = 'x;
        byte_stream_valid = 0;
        dec_sym = 'x;

        case (decode_state)
            DECODE_IDLE : begin
                if (packet_buffer_valid) begin
                    next_decode_state = DECODE_ICAO;
                    next_idx = 0;
                end
            end

            DECODE_ICAO : begin
                next_idx = idx + 1;
                dec_sym = packet_buffer_data[(76-(idx*4))+:4];
                byte_stream_valid = 1;
                byte_stream = decoded_hex;

                if (idx == 5) begin
                    case (type_code)
                        4'd1,4'd2,4'd3,4'd4 : begin
                            next_decode_state = DECODE_ME;
                            next_idx = 0;
                        end

                        default : next_decode_state = DECODE_DONE;
                    endcase
                end
            end

            DECODE_ME : begin
                next_idx = idx + 1;
                dec_sym = packet_buffer_data[(42-(idx*6))+:6];
                byte_stream_valid = 1;
                byte_stream = decoded_code6;

                if (idx == 7)
                    next_decode_state = DECODE_DONE;
            end

            DECODE_DONE : begin
                packet_buffer_ready = 1;
                next_decode_state = DECODE_IDLE;
            end
        endcase
    end

    hex_to_ascii hex2ascii (
        .hex_in(dec_sym[3:0]),
        .ascii_out(decoded_hex)
    );

    adsb_6bit_to_ascii adsb2ascii (
        .code_in(dec_sym),
        .ascii_out(decoded_code6)
    );


    // DEBUG
    always_ff @(posedge clk)
        if (reset) valid_cnt <= 0;
        else if (packet_buffer_ready) valid_cnt <= valid_cnt + 1;

endmodule : decode_adsb
