module system_xbar import obi_pkg::*; import addr_map_rule_pkg::*; import core_v_mini_mcu_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  obi_req_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]   master_req_i,
    output obi_resp_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]  master_resp_o,

    output obi_req_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0]    slave_req_o,
    input  obi_resp_t[core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0]   slave_resp_i

);

    localparam addr_map_rule_t [SYSTEM_XBAR_NSLAVE-1:0] ADDR_RULES = '{
        '{ idx: core_v_mini_mcu_pkg::RAM0_IDX  , start_addr: core_v_mini_mcu_pkg::RAM0_START_ADDRESS  , end_addr: core_v_mini_mcu_pkg::RAM0_END_ADDRESS  } ,
        '{ idx: core_v_mini_mcu_pkg::RAM1_IDX  , start_addr: core_v_mini_mcu_pkg::RAM1_START_ADDRESS  , end_addr: core_v_mini_mcu_pkg::RAM1_END_ADDRESS  } ,
        '{ idx: core_v_mini_mcu_pkg::PERIPHERAL_IDX , start_addr: core_v_mini_mcu_pkg::PERIPHERAL_START_ADDRESS , end_addr: core_v_mini_mcu_pkg::PERIPHERAL_END_ADDRESS } ,
        '{ idx: core_v_mini_mcu_pkg::ERROR_IDX , start_addr: core_v_mini_mcu_pkg::ERROR_START_ADDRESS , end_addr: core_v_mini_mcu_pkg::ERROR_END_ADDRESS }
    };

    localparam int unsigned PORT_SEL_WIDTH          = $clog2(core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE);
    localparam logic [PORT_SEL_WIDTH-1:0] ERROR_IDX = core_v_mini_mcu_pkg::ERROR_IDX;

    //Address Decoder
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0] [PORT_SEL_WIDTH-1:0] port_sel;

    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]       master_req_req;
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]       master_req_wen;
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]       master_resp_gnt;
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0]       master_resp_rvalid;
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0][31:0] master_resp_rdata;

    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0]        slave_req_req;
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0]        slave_resp_gnt;
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0][31:0]  slave_resp_rdata;

    //Aggregated Request Data (from Master -> slaves)
    //WE + BE + ADDR + WDATA
    localparam int unsigned REQ_AGG_DATA_WIDTH  = 1+4+32+32;
    localparam int unsigned RESP_AGG_DATA_WIDTH = 32;

    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER-1:0][REQ_AGG_DATA_WIDTH-1:0] master_req_out_data;
    logic [core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE-1:0][REQ_AGG_DATA_WIDTH-1:0]  slave_req_out_data;


    for (genvar i = 0; i < core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER; i++) begin : gen_addr_decoders
        addr_decode #(
            /// Highest index which can happen in a rule.
            .NoIndices(core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE),
            .NoRules(core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE),
            .addr_t(logic[31:0]),
            .rule_t(addr_map_rule_pkg::addr_map_rule_t)
        ) addr_decode_i
         (
            .addr_i(master_req_i[i].addr),
            .addr_map_i(ADDR_RULES),
            .idx_o(port_sel[i]),
            .dec_valid_o(),
            .dec_error_o(),
            .en_default_idx_i(1'b1),
            .default_idx_i()
        );
    end

    //unroll obi struct
    for (genvar i = 0; i < core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER; i++) begin : gen_unroll_master
         assign master_req_req[i]       = master_req_i[i].req;
         assign master_req_wen[i]       = ~master_req_i[i].we;
         assign master_req_out_data[i]  = {master_req_i[i].we, master_req_i[i].be, master_req_i[i].addr, master_req_i[i].wdata};
         assign master_resp_o[i].gnt    = master_resp_gnt[i];
         assign master_resp_o[i].rdata  = master_resp_rdata[i];
         assign master_resp_o[i].rvalid = master_resp_rvalid[i];
    end
    for (genvar i = 0; i < core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE; i++) begin : gen_unroll_slave
         assign slave_req_o[i].req      = slave_req_req[i];
         assign {slave_req_o[i].we, slave_req_o[i].be, slave_req_o[i].addr, slave_req_o[i].wdata} = slave_req_out_data[i];
         assign slave_resp_rdata[i]     = slave_resp_i[i].rdata;
         assign slave_resp_gnt[i]       = slave_resp_i[i].gnt;
         //slave_resp_i[i] valid are ignored as it is assumed the rvalid is 1 one cycle after gnt
    end

    //Crossbar instantiation
    xbar #(
           .NumIn(core_v_mini_mcu_pkg::SYSTEM_XBAR_NMASTER),
           .NumOut(core_v_mini_mcu_pkg::SYSTEM_XBAR_NSLAVE),
           .ReqDataWidth(REQ_AGG_DATA_WIDTH),
           .RespDataWidth(RESP_AGG_DATA_WIDTH),
           .RespLat(1), //slave valid is generated from here
           .WriteRespOn(1)
        ) i_xbar (
                        .clk_i,
                        .rst_ni,
                        .req_i   ( master_req_req      ),
                        .add_i   ( port_sel            ),
                        .wen_i   ( master_req_wen      ),
                        .wdata_i ( master_req_out_data ),
                        .gnt_o   ( master_resp_gnt     ),
                        .rdata_o ( master_resp_rdata   ),
                        .rr_i    ( '0                  ),
                        .vld_o   ( master_resp_rvalid  ),
                        .gnt_i   ( slave_resp_gnt      ),
                        .req_o   ( slave_req_req       ),
                        .wdata_o ( slave_req_out_data  ),
                        .rdata_i ( slave_resp_rdata    )
                        );

endmodule : system_xbar